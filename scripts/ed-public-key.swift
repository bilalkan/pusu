// Sparkle'ın dışa aktardığı EdDSA gizli anahtarından (base64, 32 baytlık tohum) açık anahtarı
// üretir. scripts/appcast.sh, Info.plist'teki SUPublicEDKey ile eşleştiğini doğrulamak için kullanır.
import CryptoKit
import Foundation

let path = CommandLine.arguments[1]
let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: text), seed.count == 32 else {
    FileHandle.standardError.write("Beklenmeyen anahtar biçimi\n".data(using: .utf8)!)
    exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
