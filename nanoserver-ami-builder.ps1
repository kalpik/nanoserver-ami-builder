# variables
$ami_version = "0.0.0"
$servercore_tag = "latest"
$key_name = "my-key"

$images = aws ec2 describe-images --owners 'self' --filters "Name=name,Values=base_ecs_win2016_nano_v$ami_version" | ConvertFrom-Json
if($images.Images.length -ne 0)
{
  Write-Output "AMI already exists"
  exit
}

Write-Output "=> Finding latest Nanoserver AMI"
$ami = aws ec2 describe-images --owners 'amazon' --filters 'Name=name,Values=Windows_Server-2016-English-Nano-Base-*' --query 'sort_by(Images, &CreationDate)[-1].[ImageId]' --output 'text'
Write-Output "=> Using the following AMI: $ami"

$instance = aws ec2 run-instances --image-id $ami --count 1 --instance-type t2.medium --key-name $key_name --security-group-ids sg-ba5c4fc3 --subnet-id subnet-47cb2820 --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=50}' --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Nano Builder}]' 'ResourceType=volume,Tags=[{Key=Name,Value=Nano Builder}]' --output json | ConvertFrom-Json

$instanceid = $instance.Instances.InstanceId
Write-Output "=> Instance ID is: $instanceid"
$instanceip = $instance.Instances.PrivateIpAddress
Write-Output "=> Instance IP is: $instanceip"

Write-Output "=> Waiting for password"
aws ec2 wait password-data-available --instance-id $instanceid

$password = aws ec2 get-password-data --instance-id  $instanceid --priv-launch-key .\$key_name.pem --output json | ConvertFrom-Json

$password = $password.PasswordData
Write-Output "=> Password is: $password"

$password = ConvertTo-SecureString $password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ("~\Administrator", $password)
Start-Service winrm
Set-Item WSMan:\LocalHost\Client\TrustedHosts * -Force

$session = New-PSSession -ComputerName $instanceip -Credential $credential
Write-Output "=> Now inside VM"
Invoke-Command -Session $session {hostname}
Write-Output "=> Adding docker repository"
Invoke-Command -Session $session {Install-PackageProvider -Name NuGet -Force -Verbose}
Invoke-Command -Session $session {Install-Module -Name DockerMsftProvider -Repository PSGallery -Force -Verbose}
Write-Output "=> Installing Docker"
Invoke-Command -Session $session {Install-Package -Name docker -ProviderName DockerMsftProvider -Force -Verbose}
Write-Output "=> Installing windows updates"
Invoke-Command -Session $session {icim (ncim MSFT_WUOperationsSession -Namespace root/Microsoft/Windows/WindowsUpdate) -MethodName ApplyApplicableUpdates}
Write-Output "=> Rebooting VM"
Invoke-Command -Session $session {Restart-Computer}
Start-Sleep 20
Write-Output "=> Exited VM. Waiting for VM to reboot"
hostname
while ($true) { if (Test-NetConnection $instanceip -Port 5985 | ? { $_.TcpTestSucceeded }) { break } "Waiting for VM to be up" }
$session = New-PSSession -ComputerName $instanceip -Credential $credential
Write-Output "=> Now inside VM"
Invoke-Command -Session $session {hostname}
Write-Output "=> Configuring docker"
Invoke-Command -Session $session {New-Item -Type File c:\ProgramData\docker\config\daemon.json}
Invoke-Command -Session $session {Add-Content 'C:\ProgramData\docker\config\daemon.json' '{ "hosts": ["tcp://0.0.0.0:2375", "npipe://"] }'}
Invoke-Command -Session $session {Restart-Service docker}
Write-Output "=> Pulling servercore image"
$docker_image = "microsoft/windowsservercore:$servercore_tag"
Invoke-Command -Session $session {docker pull $Using:docker_image}
Write-Output "=> Configuring EC2 launch"
Invoke-Command -Session $session {C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeInstance.ps1 -Schedule}
Write-Output "=> Shutting Down VM"
Invoke-Command -Session $session {Stop-Computer}
Sleep 20
aws ec2 wait instance-stopped --instance-ids $instanceid
Write-Output "=> Creating AMI"
$ami_id = aws ec2 create-image --instance-id $instanceid --name "base_ecs_win2016_nano_v$ami_version" --description "An AMI for nanoserver ECS host" --output text
Write-Output "=> Waiting for AMI to be available"
do {
  aws ec2 wait image-available --image-ids $ami_id
} until ($?)
Write-Output "AMI available: $ami_id. Terminating VM"
aws ec2 terminate-instances --instance-ids $instanceid
