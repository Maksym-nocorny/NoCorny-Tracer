import Cocoa
import CoreText
import os

public struct AppFonts {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoCornyTracer", category: "Fonts")
    
    public static func registerCustomFonts() {
        // Find them in the app bundle
        guard let bundleURL = Bundle.main.url(forResource: "NoCornyTracer_NoCornyTracer", withExtension: "bundle") else {
            // Note: In SPM, resources might be in Bundle.module. We'll use the Bundle extension from NoCornyTracerApp
            registerFrom(bundle: Bundle.appResources)
            return
        }
        
        guard let bundle = Bundle(url: bundleURL) else {
            registerFrom(bundle: Bundle.appResources)
            return
        }
        
        registerFrom(bundle: bundle)
    }
    
    private static func registerFrom(bundle: Bundle) {
        let ext = "ttf"
        let fontURLs = bundle.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
        
        // Also check root if not in "Fonts" directory, based on SPM packaging
        let rootURLs = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        
        let allURLs = fontURLs + rootURLs
        
        if allURLs.isEmpty {
            logger.warning("No custom .ttf fonts found in bundle.")
            return
        }
        
        for url in allURLs {
            var error: Unmanaged<CFError>?
            // Scope limit guarantees they are unloaded when the app quits
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let err = error?.takeRetainedValue()
                logger.error("Failed to register font at \(url.lastPathComponent): \(String(describing: err))")
            } else {
                logger.debug("Successfully registered font: \(url.lastPathComponent)")
            }
        }
    }
}


