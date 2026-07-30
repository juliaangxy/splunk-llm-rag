# Architecture

This deployment creates a VPC, subnet, IAM role/profile, security group, GPU EC2 instance, and Elastic IP.

Application components run on the GPU host using Docker:
- Ollama with Foundation-Sec-8B
- Milvus, etcd, MinIO
- Splunk MLTK GPU container
- Splunk LLM-RAG container

Splunk Enterprise is installed directly on the host and configured via bootstrap scripts.
