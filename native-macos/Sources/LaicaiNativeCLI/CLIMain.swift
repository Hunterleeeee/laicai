import Darwin

@main
struct LaicaiCLIEntry {
    static func main() async {
        exit(await LaicaiCLI.run())
    }
}
