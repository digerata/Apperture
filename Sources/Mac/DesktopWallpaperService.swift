import AppKit
import CoreGraphics
import ImageIO

final class DesktopWallpaperService {
    func wallpaperImage(for window: MirrorWindow) -> CGImage? {
        guard let screen = screen(for: window),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 2200
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func screen(for window: MirrorWindow) -> NSScreen? {
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)

        return NSScreen.screens.first { screen in
            screen.frame.contains(windowCenter)
        } ?? NSScreen.main
    }
}
