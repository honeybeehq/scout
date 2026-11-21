import Foundation

@main struct SDKHTTPProof {
    static func main() {
        let server = SDKServer()
        server.onReady = { url in
            print(url)
            fflush(stdout)
        }
        server.start()
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
}
