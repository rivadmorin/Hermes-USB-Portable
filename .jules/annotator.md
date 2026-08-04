## 2024-08-03 - Shell Script Documentation Standards
**Discovery:** Shell scripts use standard `# Globals:`, `# Arguments:`, and `# Returns:` block comments for functions, rather than JSDoc or PyDoc. PowerShell scripts use `<# .SYNOPSIS ... #>` block comments.
**Analysis:** Knowing the correct comment format for the specific language (Bash/PowerShell) is critical for consistency.
**Action:** When documenting Bash scripts, use standard shell script comment format. When documenting PowerShell, use `<# .SYNOPSIS #>`.
