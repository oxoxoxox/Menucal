import AppKit

enum MenuBarDateIconRenderer {
    static func image(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> NSImage {
        let day = calendar.component(.day, from: date)

        // Bundled templates keep the same date icon on macOS 13 and newer.
        if let url = bundle.url(forResource: "MenuBarDate\(day)", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            if let retinaURL = bundle.url(forResource: "MenuBarDate\(day)@2x", withExtension: "png"),
               let data = try? Data(contentsOf: retinaURL),
               let retina = NSBitmapImageRep(data: data) {
                retina.size = image.size
                image.addRepresentation(retina)
            }
            image.isTemplate = true
            return image
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let image = NSImage(systemSymbolName: "\(day).calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            image.isTemplate = true
            return image
        }

        // Keep the date readable even if an installation is missing its image resources.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let text = NSAttributedString(string: String(day), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.black
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
