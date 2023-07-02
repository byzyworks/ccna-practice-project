param (
	[string]$CommentStart  = "!",    # Relevant when below is true.
	[switch]$Disclaimerize = $false, # Outputs "helper comments" and warnings against editing each destination script.
	[string]$Extension     = ".txt", # File extension of output destination scripts.
	[int]   $Padding       = 1,      # Number of newlines to separate each source script output by in the destination script.
	[string]$PrefixScript  = "",     # Path to universal destination script beginner source script (comes before edit warning disclaimer, if enabled; useful for shebangs).
	[string]$SuffixScript  = ""      # Path to universal destination script ending source script.
)

$myPath        = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition;
$srcFolder     = "src";
$srcFolderPath = Join-Path -Path $myPath -ChildPath $srcFolder;
$srcFilenames  = (Get-ChildItem -Path $srcFolderPath).Name;
$dstFolder     = "scripts";
$dstFolderPath = Join-Path -Path $myPath -ChildPath $dstFolder;
$dstPool       = Get-Content "aliases.json" -Encoding UTF8 -Raw | ConvertFrom-Json;

# Does a couple of things to get the source script list ready before the source scripts are matched.
function Clean-SrcScripts {
	param (
		[Parameter(Mandatory)]
		[array]$RawList
	)
	
	# Create a new list since removing array elements is annoying.
	$formattedList = @();
	
	# Source scripts that contain this exact string ("(WIP)") in their filename are not used in the destination script.
	foreach ($srcFilename in $RawList) {
		if (-Not ($srcFilename.Contains("(WIP)"))) {
			$formattedList += $srcFilename;
		}
	}
	
	# The order number is used to order the arrange the source scripts accordingly, but the scripts will default to being sorted alphabetically. This corrects that.
	$formattedList = $formattedList | Sort-Object {[int]($_.Split(" "))[0]};
	
	return $formattedList;
}

# Checks for one source alias against one destination alias to see if they match.
# Note a source alias only has to match one out of many destination aliases for a destination script to be matched, which is only named using its top or "canonical" name/alias.
# This function is therefore called from inside a loop as seen below.
# Per the naming convention, a source script only has one source alias.
function Get-IsMatching {
	param (
		[Parameter(Mandatory)]
		[string]$SrcAlias,
		[Parameter(Mandatory)]
		[string]$DstAlias
	)
	
	# Matches automatically if the two strings are the same.
	if ($SrcAlias.Equals($DstAlias)) {
		return $true;
	}
	
	# Heuristically, if they're the same length but not the same content, their aliases must branch off somewhere, and therefore not match.
	# If the source script's alias is longer, either the same is still true, or the source is more specific than the destination can have applied to it.
	if ($SrcAlias.Length -ge $DstAlias.Length) {
		return $false;
	}
	
	# Similar to how domain names work (with directions reversed), if a source script is applied to a super-alias of the destination, that means it is applied to the full alias as well.
	# .com is a super-domain of .com.facebook or .com.facebook.www, in other words.
	# If a source script has the alias "(com)", that means it should apply to all .com websites, while "(com.facebook)" and "(com.facebook.www)" are more specific.
	$srcAliasSplit = $SrcAlias.Split(".");
	$dstAliasSplit = $DstAlias.Split(".");
	for ($i = 0; $i -lt $srcAliasSplit.Length; $i++) {
		if ($srcAliasSplit[$i] -ne $dstAliasSplit[$i]) {
			return $false;
		}
	}
	return $true;
}

# The source script's paths are collected to be mapped to their destinations, *then* the final destination scripts are created.
function Get-SrcDstPairs {
	# Using a dictionary/map means the destination (key) won't ever be duplicated.
	$srcDstMap = @{}

	# Main loop; for each source script:
	foreach ($srcFilename in $srcFilenames) {
		# Each source script has a structured naming convention of elements delimited by spaces.
		# Except where a source script is marked as "(WIP)" anywhere, this is the regular convention of elements from left to right:
		#
		# 1. Order Number - Used to force an ordering of the source script relative to other sources. Lower-numbered scripts appear in the destination script before higher-numbered ones, otherwise, where two order numbers are the same, the code in each source is ordered arbitrarily within the destination script (technically in alphabetical order of the filename).
		# 2. Matching Alias - The namespace that the script applies to. This is matched against the aliases for a particular destination script to determine whether it should be applied to that destination script or not.
		# 3. Description - This is to distinguish the script for its intended area of application or purpose, and is not parsed.
		$srcElements = $srcFilename.Split(" ");
		$srcOrderNum = [int]$srcElements[0];
		$srcAlias    = $srcElements[1].TrimStart("(").TrimEnd(")");
		
		# For each destination script:
		foreach ($dstSet in $dstPool) {
			# The canonical name is the name of the destination script, but the other names are also set as conditions that a source script can match.
			# The first name in a set of aliases is always the canonical name of that set.
			# The JSON where the aliases are stored uses only indexed arrays to make it easier to parse.
			$dstCname = $dstSet[0];
			
			# First step is checking that the source script's alias matches at least one of the destination's aliases.
			$matched = $false;
			
			# Determine if there's a match between the source alias and one of the destination aliases.
			foreach ($dstAlias in $dstSet) {
				$matched = Get-IsMatching -SrcAlias $srcAlias -DstAlias $dstAlias;
				
				# Only one of the destination's aliases need to be matched, as only the canonical name is mapped.
				if ($matched -eq $true) {
					break;
				}
			}
			
			# On match, the source and destination are paired (many-to-many with the sources repeated).
			# It could have gone the other way (source-key-to-destination-value), but destination-to-source is more intuitive to code.
			if ($matched -eq $true) {
				# The entry for a particular destination will be null at first. It needs to be an array with all the matched source scripts.
				if (-not ($srcDstMap[$dstCname] -is [array])) {
					$srcDstMap[$dstCname] = @();
				}
				
				# Maps the source to the destination.
				$srcDstMap[$dstCname] += $srcFilename;
			}
		}
	}
	
	return $srcDstMap;
}

# Convenient micro-function.
function Write-Padding {
	for ($i = 0; $i -lt $Padding; $i++) {
		Write-Output "`n";
	}
}

# Going by each destination file, the contents are gathered in memory and output to a file in the end.
function Write-DstScripts {
	param (
		[Parameter(Mandatory)]
		[hashtable]$SrcDstMap
	)
	
	# The prefix and suffix scripts are universal, so they do not need to be read more than once.
	if ($PrefixScript -ne "") {
		$prefixContent = Get-Content -Path $PrefixScript -Encoding UTF8 -Raw;
	}
	if ($SuffixScript -ne "") {
		$suffixContent = Get-Content -Path $SuffixScript -Encoding UTF8 -Raw;
	}
	$paddingContent = Write-Padding;
	
	# Create the destination script directory if it doesn't exist.
	if (-not (Test-Path -PathType "container" -Path $dstFolderPath)) {
		New-Item -ItemType "directory" -Path $dstFolderPath
	}
	
	# Now do the work; for each destination script:
	$SrcDstMap.GetEnumerator() | ForEach-Object {
		$bodyContent = "";
		
		# The destination script is formed from the folder they are all placed in plus the canonical name/alias and the user-provided(?) extension.
		# The canonical name, in the case of what this script was made for, is supposed to be an identifier for a single host.
		$dstFilepath = Join-Path -Path $dstFolderPath -ChildPath ($_.Key + $Extension);
		
		# Check if the destination script exists.
		if (Test-Path -PathType "leaf" -Path $dstFilepath) {
			# If it does, refresh the destination script to clear out old data.
			Clear-Content -Path $dstFilepath;
		} else {
			# If not, create it.
			New-Item -ItemType "file" -Path $dstFilepath;
		}
		
		# Write the script prefix.
		if ($PrefixScript -ne "") {
			$bodyContent += $prefixContent;
			$bodyContent += $paddingContent;
		}
		
		# Generate a warning line to discourage editing the generated script (if the script user enables disclaimers).
		if ($Disclaimerize -eq $true) {
			$bodyContent += Write-Output $CommentStart" DO NOT EDIT; this script was generated from a number of sources that are identified and demarcated in sections below. Edit those instead.`n";
			$bodyContent += $paddingContent;
		}
		
		# Append every source script previously matched to the current destination script.
		foreach ($srcFilename in $_.Value) {
			# Generate a source code referral comment (if the script user enables disclaimers).
			if ($Disclaimerize -eq $true) {
				$bodyContent += Write-Output $CommentStart' Source: "'$srcFilename"`"`n";
				$bodyContent += $paddingContent;
			}
			
			# Append the matched source script's content to the destination script in the correct order.
			$bodyContent += Get-Content -Path (Join-Path -Path $srcFolderPath -ChildPath $srcFilename) -Encoding UTF8 -Raw;
			$bodyContent += $paddingContent;
		}
		
		# Write the script suffix.
		if ($SuffixScript -ne "") {
			$bodyContent += $suffixContent;
		}
		
		# Standardizes on using LF line endings in the destination scripts (have not found any situation where this causes problems on Windows, as opposed to CRLF on Mac or Linux).
		# This also stops differences between the source scripts from causing the destination script to vary between both line endings.
		$bodyContent = $bodyContent -Replace "`r`n", "`n";
		
		# Finally write the destination script to the filesystem.
		Out-File -InputObject $bodyContent -FilePath $dstFilepath -Encoding UTF8 -NoNewLine;
	}
}

# Main program.
$srcFilenames = Clean-SrcScripts -RawList $srcFilenames;
$srcDstMap = Get-SrcDstPairs;
Write-DstScripts -SrcDstMap $srcDstMap;
