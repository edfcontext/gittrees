import Foundation
import Testing
@testable import GitTreesCore

@Suite("GitIdentity")
struct GitIdentityTests {

    @Test("an identity set entirely on the repository reports repository scope")
    func repositoryScope() {
        let identity = GitIdentity(
            name: "Dev",
            email: "dev@example.com",
            localName: "Dev",
            localEmail: "dev@example.com"
        )

        #expect(identity.scope == .repository)
        #expect(identity.isComplete)
        #expect(identity.isPinnedToRepository)
        #expect(identity.displayName == "Dev <dev@example.com>")
    }

    @Test("an identity with no local values is inherited")
    func inheritedScope() {
        let identity = GitIdentity(name: "Dev", email: "dev@example.com")

        #expect(identity.scope == .inherited)
        #expect(identity.isComplete)
        #expect(!identity.isPinnedToRepository)
    }

    @Test("pinning only one of the two fields is reported as mixed, not as fully local")
    func mixedScope() {
        let identity = GitIdentity(
            name: "Work Dev",
            email: "dev@example.com",
            localName: "Work Dev"
        )

        #expect(identity.scope == .mixed)
        #expect(identity.isPinnedToRepository)
    }

    @Test("a missing name or email leaves the identity unusable for committing")
    func unsetScope() {
        #expect(GitIdentity().scope == .unset)
        #expect(!GitIdentity(name: "Dev").isComplete)
        #expect(!GitIdentity(email: "dev@example.com").isComplete)
        #expect(GitIdentity(name: "Dev").displayName == nil)
    }

    @Test("empty strings from git config are treated as absent, not as a blank name")
    func emptyValuesAreNormalised() {
        let identity = GitIdentity(name: "", email: "", localName: "", localEmail: "")

        #expect(identity.name == nil)
        #expect(identity.email == nil)
        #expect(identity.scope == .unset)
        #expect(!identity.isPinnedToRepository)
    }
}
