param([string]$Address = '127.0.0.1', [int]$Port = 27016)
$ErrorActionPreference = 'Stop'
$udp = [Net.Sockets.UdpClient]::new()
try {
    $udp.Client.ReceiveTimeout = 3000
    $challenge = [Guid]::NewGuid().ToString('N')
    $request = [byte[]](255,255,255,255) + [Text.Encoding]::ASCII.GetBytes("getinfo $challenge")
    $udp.Connect($Address, $Port)
    [void]$udp.Send($request, $request.Length)
    $sender = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
    $bytes = $udp.Receive([ref]$sender)
    $response = [Text.Encoding]::ASCII.GetString($bytes)
    if (!$response.Contains('infoResponse')) { throw 'Unexpected UDP response.' }
    $fields = $response.Substring($response.IndexOf('\') + 1).TrimEnd([char]0,[char]10,[char]13).Split('\')
    $info = [ordered]@{}
    for ($i=0; $i+1 -lt $fields.Count; $i+=2) { $info[$fields[$i]] = $fields[$i+1] }
    if ($info.challenge -ne $challenge) { throw 'UDP challenge mismatch.' }
    if ($info.clients -notmatch '^\d+$') { throw 'Missing or invalid client count.' }
    [pscustomobject]$info
} finally { $udp.Dispose() }
