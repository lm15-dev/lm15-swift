import Foundation
import LM15

@main struct VetMain {
    static func main() async {
        while let line = readLine() {
            if line.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { continue }
            var id: JSONValue = .null
            let reply: JSONValue
            do {
                let msg = try JSONValue.parse(line); id = msg["id"]
                reply = ["id":id,"ok":true,"result":try await Vet.handle(msg)]
            } catch let e as LM15Error { reply = ["id":id,"ok":false,"error":e.toJSON()] }
            catch { reply = ["id":id,"ok":false,"error":["type":.string(String(describing:type(of:error))),"message":.string(String(describing:error))]] }
            FileHandle.standardOutput.write(Data(((try? reply.jsonString()) ?? "{\"ok\":false}").appending("\n").utf8))
        }
    }
}
