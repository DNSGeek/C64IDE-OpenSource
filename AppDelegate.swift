//  AppDelegate.swift
//  C64 IDE
//
//  Main application delegate. Manages the app lifecycle, tool windows, and global state.

import Cocoa
import SwiftUI

/// Main application delegate for the C64 IDE.
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Tool Window Controllers

    /// Main editor and build window.
    var mainWindowController: MainWindowController?
    /// Sprite editing window.
    var spriteEditorController: SpriteEditorWindowController?
    /// Character set editing window.
    var charEditorController: CharEditorWindowController?
    /// Source-level debugger window.
    var debuggerController: DebuggerWindowController?
    /// 6502 memory disassembler window.
    var disassemblerController: DisassemblerWindowController?
    /// D64 disk image browser window.
    var diskBrowserController: D64BrowserWindowController?
    /// TAP tape image browser window.
    var tapBrowserController: TAPBrowserWindowController?
    /// SID sound chip editor window.
    var sidEditorController: SIDEditorWindowController?
    /// Graphics editor window.
    var gfxEditorController: GfxEditorWindowController?
    /// Number base converter window.
    var numberConverterController: NumberConverterWindowController?
    /// PETSCII character map window.
    var petsciiMapController: PETSCIIMapWindowController?
    /// Image format converter window.
    var imageConverterController: ImageConverterWindowController?
    /// Plugin editor window.
    var pluginEditorController: PluginEditorWindowController?
    /// ROM character viewer window.
    var charROMViewerController: CharROMViewerWindowController?
    /// Tile map editor window.
    var mapEditorController: MapEditorWindowController?
    /// Memory map viewer window.
    var memoryMapController: MemoryMapWindowController?

    // MARK: - Internal State

    /// URLs pending opening (used during app launch before the main window exists).
    var pendingURLsToOpen: [URL] = []
    /// One-shot continuation fired after the next build completes. Set via
    /// runAfterNextBuild(_:_:); used by Build & Debug and Build & Save to Disk.
    var pendingBuildContinuation: ((BuildResult) -> Void)?
    /// Optional reference to the active About panel.
    var aboutPanel: NSPanel?
}

