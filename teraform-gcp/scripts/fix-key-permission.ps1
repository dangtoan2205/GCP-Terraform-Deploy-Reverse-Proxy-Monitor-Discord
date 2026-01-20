param (
  [string]$KeyPath
)

if (!(Test-Path $KeyPath)) {
  Write-Error "Key file not found: $KeyPath"
  exit 1
}

Write-Host "Fixing ACL for $KeyPath"

# 1. Remove inheritance
icacls $KeyPath /inheritance:r | Out-Null

# 2. Remove dangerous default groups
icacls $KeyPath /remove:g Users | Out-Null
icacls $KeyPath /remove:g Administrators | Out-Null
icacls $KeyPath /remove:g SYSTEM | Out-Null

# 3. Grant read permission to current user only
icacls $KeyPath /grant:r "$env:USERNAME:(R)" | Out-Null

# 4. Verify
icacls $KeyPath
