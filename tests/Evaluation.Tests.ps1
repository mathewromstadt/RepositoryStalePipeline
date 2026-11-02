BeforeAll {Import-Module "$PSScriptRoot/../Modules/BranchLifecycle/Evaluation.psm1" -Force}
Describe 'Branch protection' {
 It 'protects QA and staging' {
  Test-ProtectedBranch -Ref 'refs/heads/qa' -Patterns @('qa','staging') -DefaultBranch 'refs/heads/main' | Should -BeTrue
  Test-ProtectedBranch -Ref 'refs/heads/staging' -Patterns @('qa','staging') -DefaultBranch 'refs/heads/main' | Should -BeTrue
 }
 It 'protects repository default branch regardless of name' {
  Test-ProtectedBranch -Ref 'refs/heads/trunk' -Patterns @('main') -DefaultBranch 'refs/heads/trunk' | Should -BeTrue
 }
 It 'does not protect feature branches' {
  Test-ProtectedBranch -Ref 'refs/heads/feature/a' -Patterns @('main','release/*') -DefaultBranch 'refs/heads/main' | Should -BeFalse
 }
}
