//  main.swift
//  C64 IDE
//
//  Explicit application entry point. Used instead of @main or storyboards to
//  maintain full control over delegate initialization and the run loop lifecycle.

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

