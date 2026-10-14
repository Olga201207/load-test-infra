variable "name" {
  description = "VPC 및 하위 리소스 이름 접두사"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR. /16 을 전제로 서브넷을 나눈다."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) == 16
    error_message = "cidr 은 /16 이어야 한다 (예: 10.40.0.0/16)."
  }
}

variable "tags" {
  description = "추가 태그"
  type        = map(string)
  default     = {}
}
