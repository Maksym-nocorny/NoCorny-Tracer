import Foundation

extension Bundle {
    /// Safe bundle accessor for resources when running as a .app from SPM build
    static var appResources: Bundle {
        let bundleName = "NoCornyTracer_NoCornyTracer"
        let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle") ??
                        Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle")
        return Bundle(url: bundleURL) ?? Bundle.main
    }
}
