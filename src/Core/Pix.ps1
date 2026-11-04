# Donations by Pix (Brazil's instant payments). The "copia e cola" text and the QR code follow the
# Banco Central's static BR Code: EMV fields (ID, two-digit length, value) closed by a CRC16.
# assets\pix-qr.png is drawn from Get-PcPixPayload by tools\Build-PixQr.ps1.

function Get-PcCrc16([string]$Text) {
    # CRC-16/CCITT-FALSE: polynomial 0x1021, start 0xFFFF, as the Pix manual specifies
    $crc = 0xFFFF
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($Text)) {
        $crc = $crc -bxor ([int]$b -shl 8)
        for ($i = 0; $i -lt 8; $i++) {
            if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF }
            else { $crc = ($crc -shl 1) -band 0xFFFF }
        }
    }
    '{0:X4}' -f $crc
}

function Get-PcPixPayload {
    param(
        [string]$Key = $script:PcDonation.PixKey,
        [string]$Name = $script:PcDonation.PixName,
        [string]$City = $script:PcDonation.PixCity
    )
    function Field([string]$Id, [string]$Value) { '{0}{1:D2}{2}' -f $Id, $Value.Length, $Value }
    # No amount (field 54): whoever pays chooses how much
    $payload = (Field '00' '01') +
        (Field '26' ((Field '00' 'br.gov.bcb.pix') + (Field '01' $Key))) +
        (Field '52' '0000') + (Field '53' '986') + (Field '58' 'BR') +
        (Field '59' $Name) + (Field '60' $City) +
        (Field '62' (Field '05' '***')) + '6304'
    $payload + (Get-PcCrc16 $payload)
}
