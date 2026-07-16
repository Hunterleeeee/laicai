import XCTest

@testable import LaicaiNativeFoundation

final class StorageIsolationTests: XCTestCase {
    func testTestProcessUsesIsolatedApplicationSupport() {
        XCTAssertTrue(LaicaiStoragePaths.isRunningTests)

        let productionDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Laicai", isDirectory: true).standardizedFileURL
        let isolatedDirectory = LaicaiStoragePaths.appDirectory.standardizedFileURL

        XCTAssertNotEqual(isolatedDirectory, productionDirectory)
        XCTAssertTrue(
            isolatedDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        )
        XCTAssertNotEqual(LaicaiStoragePaths.keychainService, "com.laicai.native.secrets")
    }

    func testTestDefaultsDoNotWriteStandardDefaults() {
        let key = "laicai.storage-isolation.\(UUID().uuidString)"
        LaicaiStoragePaths.defaults.set("isolated", forKey: key)

        XCTAssertEqual(LaicaiStoragePaths.defaults.string(forKey: key), "isolated")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }
}
