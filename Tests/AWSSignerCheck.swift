import Foundation

@main
enum AWSSignerCheck {
    static func main() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!)
        request.httpMethod = "GET"

        let signer = AWSSigner(
            accessKey: "AKIAIOSFODNN7EXAMPLE",
            secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1"
        )
        signer.sign(
            &request,
            service: "s3",
            body: Data(),
            now: Date(timeIntervalSince1970: 1_369_353_600)
        )

        let expected = "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
        precondition(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(expected) == true)
        print("AWS SigV4 official test vector OK.")
    }
}
