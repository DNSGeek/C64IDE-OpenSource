//  NSTextField+Shake.swift
//  C64 IDE
//
//  Brief horizontal shake animation for invalid input feedback.
//  Extracted from MainWindowController so dialog sheets can use it too.

import AppKit

extension NSTextField {
    /// Briefly shakes the field horizontally to signal invalid input.
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.35
        animation.values = [0, -8, 8, -6, 6, -3, 3, 0]
        wantsLayer = true
        layer?.add(animation, forKey: "shake")
    }
}
