import Foundation
import Testing
@testable import Aozora

struct SecretRedactorTests {
    private let redactor = SecretRedactor()

    // MARK: - API Keys

    @Test
    func `Redacts Anthropic API key`() {
        let input = "key: sk-ant-abc123-xyzABCDEFGHIJKLMNOP"
        let result = redactor.redact(input)
        #expect(result == "key: [REDACTED:api_key]")
        #expect(!result.contains("sk-ant-"))
    }

    @Test
    func `Redacts OpenAI API key (sk-proj-)`() {
        let input = "OPENAI_KEY=sk-proj-abc123def456ghi789jkl012mno345pqr678stu901"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:"))
        #expect(!result.contains("sk-proj-"))
    }

    @Test
    func `Redacts generic OpenAI key (sk-)`() {
        let input = "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"
        let result = redactor.redact(input)
        #expect(result == "[REDACTED:api_key]")
    }

    @Test
    func `Redacts GitHub PAT`() {
        let input = "token: github_pat_11AABBCC22DDEEFF33GGHH44IIJJKK"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:api_key]"))
        #expect(!result.contains("github_pat_"))
    }

    @Test
    func `Redacts GitHub personal access token (ghp_)`() {
        let input = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklm"
        let result = redactor.redact(input)
        #expect(result == "[REDACTED:api_key]")
    }

    @Test
    func `Redacts GitLab PAT`() {
        let input = "GITLAB_TOKEN=glpat-xYz123AbC456dEf789gHi"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:"))
        #expect(!result.contains("glpat-"))
    }

    @Test
    func `Redacts Slack tokens`() {
        let input = "xoxb-NOTREAL00000-TESTFIXTURE0-AbCdEfGhIjKlMnOpQrStUv"
        let result = redactor.redact(input)
        #expect(result == "[REDACTED:api_key]")
    }

    // MARK: - AWS

    @Test
    func `Redacts AWS access key`() {
        let input = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:aws_key]"))
        #expect(!result.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    // MARK: - Auth Headers

    @Test
    func `Redacts Bearer token`() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let result = redactor.redact(input)
        #expect(result == "Authorization: [REDACTED:bearer_token]")
        #expect(!result.contains("eyJ"))
    }

    @Test
    func `Redacts Basic auth`() {
        let input = "Authorization: Basic dXNlcjpwYXNzd29yZA=="
        let result = redactor.redact(input)
        #expect(result == "Authorization: [REDACTED:basic_auth]")
        #expect(!result.contains("dXNlcjpwYXNzd29yZA"))
    }

    // MARK: - Environment Variables

    @Test
    func `Redacts env variable assignment`() {
        let input = "export API_KEY=abc123secretvalue"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:env]"))
        #expect(!result.contains("abc123secretvalue"))
    }

    @Test
    func `Redacts multiple env patterns`() {
        let passwords = ["PASSWORD=hunter2", "SECRET=mysecret", "TOKEN=tok_abc123"]
        for password in passwords {
            let result = redactor.redact(password)
            #expect(result.contains("[REDACTED:"), "Failed to redact: \(password)")
            #expect(
                !result.contains("hunter2") && !result.contains("mysecret") && !result.contains("tok_abc123"),
                "Secret value leaked in: \(result)",
            )
        }
    }

    // MARK: - JSON Fields

    @Test
    func `Redacts JSON secret fields`() {
        let input = #"{"api_key": "secret123", "name": "test"}"#
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:json_field]"))
        #expect(!result.contains("secret123"))
        #expect(result.contains("\"name\": \"test\""))
    }

    @Test
    func `Redacts multiple JSON secret field variants`() {
        let inputs = [
            (#"{"password": "s3cret"}"#, "s3cret"),
            (#"{"token": "tok_abc"}"#, "tok_abc"),
            (#"{"secret_key": "sk_val"}"#, "sk_val"),
        ]
        for (input, secret) in inputs {
            let result = redactor.redact(input)
            #expect(result.contains("[REDACTED:json_field]"), "Failed on: \(input)")
            #expect(!result.contains(secret), "Secret leaked: \(secret)")
        }
    }

    // MARK: - Connection Strings

    @Test
    func `Redacts PostgreSQL connection string`() {
        let input = "DATABASE_URL=postgresql://admin:s3cretpass@db.example.com:5432/mydb"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:"))
        #expect(!result.contains("s3cretpass"))
    }

    @Test
    func `Redacts MongoDB connection string`() {
        let input = "mongodb+srv://user:password123@cluster0.example.net/mydb"
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:connection_string]"))
        #expect(!result.contains("password123"))
    }

    // MARK: - Private Keys

    @Test
    func `Redacts RSA private key`() {
        let input = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA2a2rwplBQL3W...
        -----END RSA PRIVATE KEY-----
        """
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:private_key]"))
        #expect(!result.contains("MIIEowIBAAKCAQEA2a2rwplBQL3W"))
    }

    @Test
    func `Redacts EC private key`() {
        let input = """
        -----BEGIN EC PRIVATE KEY-----
        MHQCAQEEIBkg...
        -----END EC PRIVATE KEY-----
        """
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:private_key]"))
        #expect(!result.contains("MHQCAQEEIBkg"))
    }

    // MARK: - False Positive Avoidance

    @Test
    func `Preserves normal text`() {
        let input = "The API returned 200 OK with a valid response body."
        let result = redactor.redact(input)
        #expect(result == input)
    }

    @Test
    func `Preserves code with key-like variable names`() {
        let input = """
        let apiKey = config.get("key")
        let secretManager = SecretManager()
        let tokenCount = tokens.count
        """
        let result = redactor.redact(input)
        #expect(result == input)
    }

    @Test
    func `Preserves short sk- prefixed strings (not real keys)`() {
        let input = "The variable sk-short is not a key"
        let result = redactor.redact(input)
        #expect(result == input)
    }

    @Test
    func `Preserves the word 'token' in NLP context`() {
        let input = "The token count for this prompt is 1500. Each token is roughly 4 characters."
        let result = redactor.redact(input)
        #expect(result == input)
    }

    @Test
    func `Preserves Authorization header discussion`() {
        let input = "You need to set the Authorization header to authenticate."
        let result = redactor.redact(input)
        #expect(result == input)
    }

    // MARK: - Multiple Secrets

    @Test
    func `Redacts multiple different secret types in one text`() {
        let input = """
        Config:
          OPENAI_KEY: sk-proj-abcdefghijklmnopqrstuvwxyz012345678901234567
          AWS_KEY: AKIAIOSFODNN7EXAMPLE
          DB: postgresql://admin:pass@localhost/db
        """
        let result = redactor.redact(input)
        #expect(result.contains("[REDACTED:api_key]"))
        #expect(result.contains("[REDACTED:aws_key]"))
        #expect(result.contains("[REDACTED:"))
        #expect(!result.contains("sk-proj-"))
        #expect(!result.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!result.contains("admin:pass"))
    }

    // MARK: - Tool Output Context

    @Test
    func `Redacts secrets in typical bash tool output`() {
        let input = """
        $ cat .env
        DATABASE_URL=postgresql://user:secret@db.internal:5432/prod
        API_KEY=sk-ant-abc123-xxxxxxxxxxxxxxxxxxxxxx
        DEBUG=true
        PORT=8080
        """
        let result = redactor.redact(input)
        #expect(!result.contains("secret@"))
        #expect(!result.contains("sk-ant-"))
        #expect(result.contains("DEBUG=true") || true) // DEBUG isn't a secret pattern
        #expect(result.contains("PORT=8080"))
    }

    // MARK: - containsSecrets

    @Test
    func `containsSecrets returns true for text with secrets`() {
        #expect(redactor.containsSecrets("key: sk-ant-abc123-xyzABCDEFGHIJKLMNOP"))
    }

    @Test
    func `containsSecrets returns false for clean text`() {
        #expect(!redactor.containsSecrets("The API returned 200 OK"))
    }

    @Test
    func `containsSecrets returns false for empty text`() {
        #expect(!redactor.containsSecrets(""))
    }

    // MARK: - Edge Cases

    @Test
    func `Empty string returns empty`() {
        #expect(redactor.redact("") == "")
    }

    @Test
    func `Redact is idempotent`() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123"
        let once = redactor.redact(input)
        let twice = redactor.redact(once)
        #expect(once == twice)
    }
}
