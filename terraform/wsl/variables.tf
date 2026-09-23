variable "ssh_public_key" {
  description = "Din publika SSH-nyckel som läggs in i alla noder (för Ansible-åtkomst)"
  type        = string
}

variable "node_count" {
  description = "Antal Ubuntu-noder (3 för ett MongoDB replica set). Sätt 1 för ett rökprov."
  type        = number
  default     = 3
}

variable "memory_mb" {
  description = <<-EOT
    RAM per nod i MB. node_count * memory_mb + overhead är vad WSL-instansen behöver ha
    tillgängligt; defaulten nedan ger 3 x 2048 MB = 6 GB. Sänk om du kör med mindre.
  EOT
  type        = number
  default     = 2048
}

variable "vcpu" {
  description = "Antal vCPU per nod. Får översättas mot färre fysiska trådar, det är ok i ett labb."
  type        = number
  default     = 2
}

variable "disk_size_gb" {
  description = "Diskstorlek per nod i GB. qcow2 är cow-klonad, så den växer efter behov."
  type        = number
  default     = 20
}

variable "stopped_nodes" {
  description = "Nodnummer (1-baserat, t.ex. [2]) som ska vara avstängda. Tom lista = alla körs. Diskarna behålls."
  type        = list(number)
  default     = []
}
