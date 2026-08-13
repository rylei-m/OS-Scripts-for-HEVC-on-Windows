$<#
.SYNOPSIS
  A short one-line action-based description, e.g. 'Tests if a function is valid'
.DESCRIPTION
  A longer description of the function, its purpose, common use cases, etc.
.NOTES
  Information or caveats about the function e.g. 'This function is not supported in Linux'
.LINK
  Specify a URI to a help page, this will show when Get-Help -Online is used.
.EXAMPLE
  Test-MyTestFunction -Verbose
  Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>

param(
  [Alias["h"]
  [switch]$Help  
)

if ($Help.IsPresent) {
    Get-Help $MyInvocation.MyCommand.Path 
    exit 
  }

#Constants
Set-Variable -Name PHOTOS_APPX -Option Constant -Value @{
    ProductId = '9WZDNCRFJBH4'
    PackageFamilyName = 'Microsoft.Windows.Photos_8wekyb3d8bbwe'
    Name = 'Microsoft.Windows.Photos'
  }
Set-Variable -Name HEIF_APPX -Option Constant -Value @{
    ProductId = '9PMMSR1CGPWG'
    PackageFamilyName = 'Microsoft.HEIFImageExtension_8wekb3d8bbwe'
    Name = 'Microsoft.HEIFImageExtension'
  }
Set-Variable -Name HEVC_APPX -Option Constant -Value @{
    ProductId = '9N4WGH0Z6VHQ'
    PackageFamilyName = 'Mi .HEVCVideoExtension_8wekyb3d8bbwe'
    Name = 'Microsoft.HEVCVideoExtension'
  }

