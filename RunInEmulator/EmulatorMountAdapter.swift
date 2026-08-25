import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - DiskMountPlan
// ═══════════════════════════════════════════════════════════

/// The resolved set of disks to mount and how to boot the primary one.
///
/// Produced by `EmulatorMountAdapter.plan(for:projectRoot:)` and consumed by
/// the per-emulator argument builders. Separating resolution from
/// argument-building means both VICE and xemu get the same plan, and the
/// plan can be unit-tested without spawning a process.
struct DiskMountPlan {

    /// Represents a single disk image to be mounted in the emulator.
    struct MountedDisk {
        let driveNumber: Int        // 8–11
        let imageURL: URL
        let label: String
    }

    /// All disks to mount, sorted by drive number.
    let disks: [MountedDisk]

    /// The disk to boot from.
    ///
    /// Resolved once at plan time from the project's designated primary disk,
    /// rather than recomputed as "whatever is on drive 8". Those two answers
    /// disagree whenever the primary disk sits on another drive, and the
    /// disagreement used to pair one disk's boot-program name with a different
    /// disk's image.
    let primaryDisk: MountedDisk?

    /// CBM name of the boot program on the primary disk, or nil (= "*").
    let bootProgramName: String?

    /// True when there is at least one disk to mount.
    var hasMounts: Bool { !disks.isEmpty }
}

// ═══════════════════════════════════════════════════════════
// MARK: - EmulatorMountAdapter
// ═══════════════════════════════════════════════════════════

/// Resolves a project's `ProjectDiskConfig` into a `DiskMountPlan` and then
/// builds the command-line arguments for a specific emulator.
///
/// All methods are static — this is a pure utility namespace, not a service
/// with state. Both VICE and xemu adapters call into it.
enum EmulatorMountAdapter {

    // MARK: - Plan resolution

    /// Build a `DiskMountPlan` from the active project's disk config.
    ///
    /// - Parameters:
    ///   - config:    The project's disk configuration.
    ///   - projectRoot: Project root URL, used to resolve relative image paths.
    /// - Returns: A plan, or nil if config is empty or no images are on disk.
    static func plan(
        for config: ProjectDiskConfig,
        projectRoot: URL
    ) -> DiskMountPlan? {

        var mounts: [DiskMountPlan.MountedDisk] = []
        // Resolved together, so the boot-program name can only ever describe an
        // image that actually made it into the plan.
        var primaryMount: DiskMountPlan.MountedDisk?
        var primaryBootName: String?

        for disk in config.disks {
            let imageURL = projectRoot.appendingPathComponent(disk.filename)
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                // Image wasn't produced (build error on that disk) — skip it.
                continue
            }
            let mount = DiskMountPlan.MountedDisk(
                driveNumber: disk.driveNumber,
                imageURL:    imageURL,
                label:       disk.label
            )
            mounts.append(mount)

            if disk.id == config.primaryDiskID {
                primaryMount    = mount
                primaryBootName = disk.bootProgramName?.uppercased()
            }
        }

        guard !mounts.isEmpty else { return nil }

        let sorted = mounts.sorted { $0.driveNumber < $1.driveNumber }

        // The designated primary is preferred. When its image is missing we
        // fall back to the lowest-numbered drive and leave the boot name nil:
        // that name belongs to the disk that didn't build, and handing it to a
        // different image just produces ?FILE NOT FOUND on the machine.
        return DiskMountPlan(
            disks:           sorted,
            primaryDisk:     primaryMount ?? sorted.first,
            bootProgramName: primaryMount == nil ? nil : primaryBootName
        )
    }

    // MARK: - VICE argument builder

    /// Build VICE command-line arguments for mounting disks and booting.
    ///
    /// Replaces the `-autostart <prg>` inject-mode arguments that `launchVICE`
    /// currently adds. The caller should skip its normal autostart block when
    /// this returns a non-empty array.
    ///
    /// Boot syntax: `-autostart <image>:<name>` where `<name>` is the CBM
    /// filename to load and run. Omitting `:<name>` means VICE loads the
    /// first file it finds, which matches `LOAD"*",8,1` behaviour.
    ///
    /// Drive assignments: `-8 <image>` through `-11 <image>` for each disk.
    static func viceArguments(for plan: DiskMountPlan, autoRun: Bool) -> [String] {
        guard let primary = plan.primaryDisk else { return [] }
        var args: [String] = []

        // Autostart from primary disk
        if autoRun {
            let bootTarget: String
            if let name = plan.bootProgramName {
                bootTarget = "\(primary.imageURL.path):\(name)"
            } else {
                bootTarget = primary.imageURL.path
            }
            args += ["-autostart", bootTarget, "-autostartprgmode", "0"]
            // Mode 0 = load from disk (vs mode 1 = inject into memory).
        }

        // Drive mounts for all disks
        for disk in plan.disks {
            args += ["-\(disk.driveNumber)", disk.imageURL.path]
        }

        return args
    }

    // MARK: - xemu argument builder

    /// Build xemu command-line arguments for mounting disks and booting.
    ///
    /// xemu accepts `-8 <image>` for drive assignment and `-autoload` to
    /// RUN the first program on the boot disk. There is no per-file boot
    /// name syntax like VICE's `-autostart <image>:<name>` — the boot
    /// program ordering is handled by the bundle phase (boot program is
    /// written first on disk).
    ///
    /// Only `-8` is emitted. The MEGA65 has one internal 3.5" drive, so the
    /// `-9`/`-10`/`-11` flags this used to generate for a multi-disk project
    /// were options `xmega65` doesn't accept.
    ///
    /// The plan's boot image always goes in the one drive xemu has, whatever
    /// drive number the project assigned it. A project that puts its boot disk
    /// on drive 9 still boots that disk rather than an unrelated one — the
    /// drive number carries no meaning on a machine with a single drive.
    ///
    /// - Returns: Arguments for the boot disk, or an empty array when the plan
    ///   has nothing to mount. The caller falls back to PRG inject mode.
    static func xemuArguments(for plan: DiskMountPlan, autoRun: Bool) -> [String] {
        guard let boot = plan.primaryDisk else { return [] }

        var args = ["-8", boot.imageURL.path]
        if autoRun { args.append("-autoload") }
        return args
    }

    /// Disks the xemu launch will leave unmounted, so the caller can say so
    /// rather than letting them vanish silently.
    static func xemuUnmountedDisks(for plan: DiskMountPlan) -> [DiskMountPlan.MountedDisk] {
        guard let boot = plan.primaryDisk else { return plan.disks }
        return plan.disks.filter { $0.imageURL != boot.imageURL }
    }
}
