//  AppDelegate+Menu.swift
//  C64 IDE
//
//  Main menu bar construction and keyboard shortcut configuration.

import Cocoa

extension AppDelegate {

    /// Initializes and assigns the application's main menu.
    @MainActor func setupMainMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeBuildMenuItem())
        mainMenu.addItem(makeToolsMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeHelpMenuItem())

        NSApp.mainMenu = mainMenu
    }

    // MARK: App Menu
    private func makeAppMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About C64 IDE", action: #selector(showAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hide C64 IDE", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit C64 IDE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menuItem(submenu: menu)
    }

    // MARK: File Menu

    @MainActor private func makeFileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")

        // New submenu
        let newMenu = NSMenu(title: "New")
        newMenu.addItem(NSMenuItem(title: "New BASIC File", action: #selector(newBasicFile(_:)), keyEquivalent: "n"))
        let newAsm = NSMenuItem(title: "New Assembly File", action: #selector(newAssemblyFile(_:)), keyEquivalent: "n")
        newAsm.keyEquivalentModifierMask = [.command, .shift]
        newMenu.addItem(newAsm)
        newMenu.addItem(.separator())
        let newProject = NSMenuItem(title: "New Project…", action: #selector(newProject(_:)), keyEquivalent: "n")
        newProject.keyEquivalentModifierMask = [.command, .option]
        newMenu.addItem(newProject)
        let fromTemplate = NSMenuItem(
            title: "New Project from Template…",
            action: #selector(newProjectFromTemplate(_:)),
            keyEquivalent: ""
        )
        newMenu.addItem(fromTemplate)
        let newMenuItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newMenuItem.submenu = newMenu
        menu.addItem(newMenuItem)

        menu.addItem(NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o"))
        let openProject = NSMenuItem(title: "Open Project…", action: #selector(openProjectDocument(_:)), keyEquivalent: "o")
        openProject.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(openProject)

        // Recent Projects submenu
        let recentMenu = NSMenu(title: "Recent Projects")
        let recentMenuItem = NSMenuItem(title: "Recent Projects", action: nil, keyEquivalent: "")
        recentMenuItem.submenu = recentMenu
        recentMenuItem.tag = 9001
        menu.addItem(recentMenuItem)
        rebuildRecentProjectsMenu()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Save", action: #selector(saveCurrentDocument(_:)), keyEquivalent: "s"))
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(MainWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAs)
        menu.addItem(.separator())
        let saveProject = NSMenuItem(title: "Save Project", action: #selector(saveProject(_:)), keyEquivalent: "s")
        saveProject.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(saveProject)
        menu.addItem(NSMenuItem(title: "Close Project", action: #selector(closeProject(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let projectSettings = NSMenuItem(title: "Project Settings…", action: #selector(showProjectSettings(_:)), keyEquivalent: ",")
        projectSettings.keyEquivalentModifierMask = [.command, .shift]
        projectSettings.target = self
        menu.addItem(projectSettings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w"))
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindow)

        return menuItem(submenu: menu)
    }

    // MARK: Edit Menu

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        menu.addItem(find)
        menu.addItem(.separator())
        let renumber = NSMenuItem(title: "Renumber BASIC Lines…", action: #selector(renumberLines(_:)), keyEquivalent: "l")
        renumber.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(renumber)
        return menuItem(submenu: menu)
    }

    // MARK: Build Menu

    @MainActor private func makeBuildMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Build")
        menu.addItem(NSMenuItem(title: "Build & Run",   action: #selector(buildAndRun(_:)),   keyEquivalent: "r"))
        let debugItem = NSMenuItem(title: "Build & Debug", action: #selector(buildAndDebug(_:)), keyEquivalent: "r")
        debugItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(debugItem)
        menu.addItem(NSMenuItem(title: "Build Only", action: #selector(buildOnly(_:)),  keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Stop",       action: #selector(stopBuild(_:)), keyEquivalent: "."))
        menu.addItem(.separator())
        let d64Build = NSMenuItem(title: "Build & Save to Disk…", action: #selector(buildAndSaveToD64(_:)), keyEquivalent: "d")
        d64Build.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(d64Build)
        let compileBasic = NSMenuItem(title: "Compile BASIC to ASM", action: #selector(compileBASIC(_:)), keyEquivalent: "g")
        compileBasic.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(compileBasic)
        let asmToData = NSMenuItem(
            title: "Compile Assembly to DATA...",
            action: #selector(MainWindowController.compileAssemblyToData(_:)),
            keyEquivalent: ""
        )
        menu.addItem(asmToData)
        let prgToData = NSMenuItem(
            title: "Import PRG as DATA...",
            action: #selector(MainWindowController.importPRGAsData(_:)),
            keyEquivalent: ""
        )
        menu.addItem(prgToData)
        menu.addItem(.separator())
        let u64Run = NSMenuItem(title: "Run on U64", action: #selector(U64BuildPipeline.runOnHardware), keyEquivalent: "r")
        u64Run.keyEquivalentModifierMask = [.control, .command]
        u64Run.target = U64BuildPipeline.shared
        menu.addItem(u64Run)
        let u64Load = NSMenuItem(title: "Load on U64", action: #selector(U64BuildPipeline.loadOnHardware), keyEquivalent: "l")
        u64Load.keyEquivalentModifierMask = [.control, .command]
        u64Load.target = U64BuildPipeline.shared
        menu.addItem(u64Load)
        let u64Reset = NSMenuItem(title: "Reset U64", action: #selector(U64BuildPipeline.resetMachine), keyEquivalent: "")
        u64Reset.target = U64BuildPipeline.shared
        menu.addItem(u64Reset)
        menu.addItem(.separator())
        let m65Run = NSMenuItem(title: "Run on MEGA65", action: #selector(MEGA65BuildPipeline.runOnHardware), keyEquivalent: "m")
        m65Run.keyEquivalentModifierMask = [.control, .command]
        m65Run.target = MEGA65BuildPipeline.shared
        menu.addItem(m65Run)
        let m65Load = NSMenuItem(title: "Load on MEGA65", action: #selector(MEGA65BuildPipeline.loadOnHardware), keyEquivalent: "")
        m65Load.target = MEGA65BuildPipeline.shared
        menu.addItem(m65Load)
        return menuItem(submenu: menu)
    }

    // MARK: Tools Menu

    @MainActor private func makeToolsMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Tools")

        let spriteItem = NSMenuItem(title: "Sprite Editor", action: #selector(openSpriteEditor(_:)), keyEquivalent: "e")
        spriteItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(spriteItem)
        let charItem = NSMenuItem(title: "Character Set Editor", action: #selector(openCharEditor(_:)), keyEquivalent: "d")
        charItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(charItem)
        menu.addItem(NSMenuItem(title: "ROM Character Set Viewer", action: #selector(openCharROMViewer(_:)), keyEquivalent: "c"))
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "Debugger", action: #selector(openDebugger(_:)), keyEquivalent: "y")
        debugItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(debugItem)
        let disasmItem = NSMenuItem(title: "Disassembler", action: #selector(openDisassembler(_:)), keyEquivalent: "i")
        disasmItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(disasmItem)
        let d64Item = NSMenuItem(title: "Disk Browser", action: #selector(openD64Browser(_:)), keyEquivalent: "k")
        d64Item.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(d64Item)
        let tapItem = NSMenuItem(title: "Tape Browser", action: #selector(openTAPBrowser(_:)), keyEquivalent: "t")
        tapItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(tapItem)
        menu.addItem(.separator())
        let sidItem = NSMenuItem(title: "SID Editor", action: #selector(openSIDEditor(_:)), keyEquivalent: "m")
        sidItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(sidItem)
        let gfxItem = NSMenuItem(title: "Graphics Editor", action: #selector(openGfxEditor(_:)), keyEquivalent: "g")
        gfxItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(gfxItem)
        menu.addItem(.separator())
        let numItem = NSMenuItem(title: "Number Converter", action: #selector(openNumberConverter(_:)), keyEquivalent: "u")
        numItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(numItem)
        let petsciiItem = NSMenuItem(title: "PETSCII Map", action: #selector(openPETSCIIMap(_:)), keyEquivalent: "p")
        petsciiItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(petsciiItem)
        menu.addItem(.separator())
        let imgItem = NSMenuItem(title: "Image Converter", action: #selector(openImageConverter(_:)), keyEquivalent: "i")
        imgItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(imgItem)
        menu.addItem(.separator())
        let mapItem = NSMenuItem(title: "Map Editor", action: #selector(openMapEditor(_:)), keyEquivalent: "m")
        mapItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(mapItem)
        menu.addItem(NSMenuItem(title: "Memory Map", action: #selector(openMemoryMap(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let u64Settings = NSMenuItem(title: "U64 Settings…", action: #selector(U64BuildPipeline.openSettings), keyEquivalent: "")
        u64Settings.target = U64BuildPipeline.shared
        menu.addItem(u64Settings)
        let m65Settings = NSMenuItem(title: "MEGA65 Settings…", action: #selector(MEGA65BuildPipeline.openSettings), keyEquivalent: "")
        m65Settings.target = MEGA65BuildPipeline.shared
        menu.addItem(m65Settings)
        menu.addItem(.separator())
        menu.addItem(makeDialectMenuItem())

        return menuItem(submenu: menu)
    }

    private func makeDialectMenuItem() -> NSMenuItem {
        let dialectMenu = NSMenu(title: "BASIC Dialect")
        let noneItem = NSMenuItem(title: "Standard BASIC V2", action: #selector(selectDialect(_:)), keyEquivalent: "")
        noneItem.tag = -1
        noneItem.target = self
        noneItem.state = .on
        dialectMenu.addItem(noneItem)
        dialectMenu.addItem(.separator())
        for (i, dialect) in BasicDialectManager.shared.availableDialects.enumerated() {
            let item = NSMenuItem(title: dialect.name, action: #selector(selectDialect(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            dialectMenu.addItem(item)
        }
        dialectMenu.addItem(.separator())
        dialectMenu.addItem(NSMenuItem(title: "Install Plugin…",      action: #selector(installPlugin(_:)),    keyEquivalent: ""))
        dialectMenu.addItem(NSMenuItem(title: "Edit Plugin…",         action: #selector(openPluginEditor(_:)), keyEquivalent: ""))
        dialectMenu.addItem(NSMenuItem(title: "Reveal Plugins Folder", action: #selector(openPluginsFolder(_:)), keyEquivalent: ""))
        let dialectMenuItem = NSMenuItem(title: "BASIC Dialect", action: nil, keyEquivalent: "")
        dialectMenuItem.submenu = dialectMenu
        return dialectMenuItem
    }

    // MARK: View Menu

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")

        let fontSubMenu = NSMenu(title: "Editor Font")
        let fontChoose = NSMenuItem(title: "Font Settings…", action: #selector(showFontPreferences(_:)), keyEquivalent: "")
        fontChoose.target = self
        fontSubMenu.addItem(fontChoose)
        fontSubMenu.addItem(.separator())
        let fontBigger = NSMenuItem(title: "Increase Size", action: #selector(increaseFontSize(_:)), keyEquivalent: "+")
        fontBigger.target = self
        fontSubMenu.addItem(fontBigger)
        let fontSmaller = NSMenuItem(title: "Decrease Size", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        fontSmaller.target = self
        fontSubMenu.addItem(fontSmaller)
        fontSubMenu.addItem(.separator())
        let fontReset = NSMenuItem(title: "Reset to Default", action: #selector(resetFontSize(_:)), keyEquivalent: "0")
        fontReset.target = self
        fontSubMenu.addItem(fontReset)
        let fontMenuItem = NSMenuItem(title: "Editor Font", action: nil, keyEquivalent: "")
        fontMenuItem.submenu = fontSubMenu
        menu.addItem(fontMenuItem)
        menu.addItem(.separator())

        let toggleRef = NSMenuItem(title: "Toggle Reference Panel", action: #selector(toggleReference(_:)), keyEquivalent: "r")
        toggleRef.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggleRef)
        let toggleBot = NSMenuItem(title: "Toggle Console", action: #selector(toggleConsole(_:)), keyEquivalent: "Y")
        toggleBot.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleBot)

        return menuItem(submenu: menu)
    }

    // MARK: Window Menu

    private func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "Zoom",     action: #selector(NSWindow.performZoom(_:)),        keyEquivalent: ""))
        NSApp.windowsMenu = menu
        return menuItem(submenu: menu)
    }

    // MARK: Help Menu

    private func makeHelpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(NSMenuItem(title: "C64 IDE Help", action: nil, keyEquivalent: ""))
        NSApp.helpMenu = menu
        return menuItem(submenu: menu)
    }

    // MARK: - Utility

    /// Wrap a populated NSMenu in a bare NSMenuItem for insertion into the menu bar.
    private func menuItem(submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }
}
