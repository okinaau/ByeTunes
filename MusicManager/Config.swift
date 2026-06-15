import Foundation

struct Config {
    static let byeTunesApiUrl: String = {
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let url = dict["ByeTunesApiUrl"] as? String {
            return url
        }
        // Fallback default so the app compiles and runs for others (with a placeholder API URL)
        return "https://api.placeholder-byetunes-xyz.com"
    }()
    
    static let byeTunesApiHost: String = {
        return URL(string: byeTunesApiUrl)?.host ?? ""
    }()
}
