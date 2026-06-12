# Parse-check a PowerShell file without running it. Usage: parse-check.ps1 -Path <file>
param([Parameter(Mandatory)][string]$Path)
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count) {
  $errors | ForEach-Object { '{0} @ line {1}' -f $_.Message, $_.Extent.StartLineNumber }
  exit 1
}
'PARSE OK'
