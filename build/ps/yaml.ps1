function Test-YamlField([string] $path, [string] $field, [string] $fieldValue) {

	yq -e "$field | select(. == ""$fieldValue"")" $path 2>$null
	$?
}

function Get-YamlField([string] $path, [string] $field) {

	$value = yq -e $field $path
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to get YAML field from $field, yq exited with code $LASTEXITCODE"
	}

	# without --header-preprocess=false, leading comments get skipped
	$line = yq --header-preprocess=false "$field | line" $path
	if ($line -eq 0) {
		throw "Failed to get line number for YAML field $field"
	}

	$zeroBasedLineNumber = $line - 1
	@($path, $zeroBasedLineNumber, $value)
}

function Set-YamlContentLine([string] $path, [string] $field, [string] $fieldValue) {

	$fieldInfo = Get-YamlField $path $field

	$lines = Get-Content $fieldInfo[0]
	$lineNumber = $fieldInfo[1]
	$currentFieldValue = $fieldInfo[2]

	# Note: using yq -i doesn't preserve whitespace
	$lines[$lineNumber] = $lines[$lineNumber].replace($currentFieldValue, $fieldValue)
	Set-Content $path $lines
}