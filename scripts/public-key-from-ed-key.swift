import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    fputs("public-key-from-ed-key: \(message)\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count == 2 else {
    fail("expected one private key file")
}

let path = CommandLine.arguments[1]
let encoded: String
do {
    encoded = try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
} catch {
    fail("could not read \(path): \(error)")
}

guard let keyData = Data(base64Encoded: encoded) else {
    fail("private key file is not base64")
}

switch keyData.count {
case 32:
    do {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        print(key.publicKey.rawRepresentation.base64EncodedString())
    } catch {
        fail("could not derive the public key: \(error)")
    }
case 96:
    print(Data(keyData.suffix(32)).base64EncodedString())
default:
    fail("decoded private key has \(keyData.count) bytes, expected 32 or 96")
}
