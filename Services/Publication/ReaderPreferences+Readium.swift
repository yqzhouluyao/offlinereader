import Foundation
import ReadiumNavigator
import ReadiumShared

extension ReaderPreferencesSnapshot {
    func makeEPUBPreferences() -> EPUBPreferences {
        let fontFamily: FontFamily?
        switch font {
        case .publisher:
            fontFamily = nil
        case .serif:
            fontFamily = .serif
        case .sansSerif:
            fontFamily = .sansSerif
        }

        let themeValue: ReadiumNavigator.Theme
        switch theme {
        case .day:
            themeValue = .light
        case .sepia:
            themeValue = .sepia
        case .eyeCare:
            themeValue = .light
        case .night:
            themeValue = .dark
        }

        return EPUBPreferences(
            backgroundColor: theme.epubBackgroundColor,
            fontFamily: fontFamily,
            fontSize: fontSizeLevel.multiplier,
            lineHeight: lineHeightLevel.lineHeight,
            pageMargins: marginLevel.margin,
            publisherStyles: false,
            scroll: pageTurnMode == .verticalScroll,
            spread: .never,
            textColor: theme.epubTextColor,
            theme: themeValue
        )
    }

    func makePDFPreferences() -> PDFPreferences {
        PDFPreferences(
            backgroundColor: theme.pdfBackgroundColor,
            fit: .width,
            pageSpacing: 10,
            scroll: pageTurnMode == .verticalScroll,
            scrollAxis: .vertical,
            spread: .never,
            visibleScrollbar: true
        )
    }
}

private extension ReaderPreferencesSnapshot.Theme {
    var epubBackgroundColor: Color? {
        switch self {
        case .day:
            nil
        case .sepia:
            nil
        case .eyeCare:
            Color(hex: "#DDEDDD")
        case .night:
            nil
        }
    }

    var epubTextColor: Color? {
        switch self {
        case .eyeCare:
            Color(hex: "#1F2A24")
        case .day, .sepia, .night:
            nil
        }
    }

    var pdfBackgroundColor: Color? {
        switch self {
        case .eyeCare:
            Color(hex: "#DDEDDD")
        case .day, .sepia, .night:
            nil
        }
    }
}

private extension ReaderPreferencesSnapshot.Level {
    var multiplier: Double {
        switch self {
        case .one: 0.85
        case .two: 0.98
        case .three: 1.08
        case .four: 1.45
        case .five: 1.85
        }
    }

    var lineHeight: Double {
        switch self {
        case .one: 1.18
        case .two: 1.32
        case .three: 1.52
        case .four: 1.68
        case .five: 1.82
        }
    }

    var margin: Double {
        switch self {
        case .one: 0.85
        case .two: 1.05
        case .three: 1.28
        case .four: 1.5
        case .five: 1.72
        }
    }
}
