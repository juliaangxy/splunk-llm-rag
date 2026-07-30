#!/usr/bin/env python3
"""
Generate containers.conf from CONTAINER_IMAGE_PROFILES_JSON and ECR_REGISTRY_URI.
Parses ECR URIs using the format: registry/repository/image:tag
"""

import json
import os
import sys
from urllib.parse import urlparse
from typing import Dict, List, Tuple


def parse_ecr_uri(full_uri: str) -> Tuple[str, str, str]:
    """
    Parse an ECR URI like:
    618246141311.dkr.ecr.ap-southeast-1.amazonaws.com/ai-splunk-ecr/splunk/image:tag
    
    Returns: (repo, image, tag)
    - repo: registry URL (before first /)
    - image: image name with tag (after last / before :)
    - tag: image name only (without tag)
    """
    # Split by first /
    parts = full_uri.split('/', 1)
    repo = parts[0]
    
    if len(parts) < 2:
        raise ValueError(f"Invalid ECR URI: {full_uri}")
    
    remainder = parts[1]  # e.g., "ai-splunk-ecr/splunk/image:tag"
    
    # Get everything after the last /
    path_parts = remainder.rsplit('/', 1)
    image_with_tag = path_parts[-1]  # e.g., "image:tag"
    
    # Split image and tag
    if ':' in image_with_tag:
        image_name, tag = image_with_tag.rsplit(':', 1)
    else:
        image_name = image_with_tag
        tag = 'latest'
    
    return repo, image_with_tag, image_name


def generate_containers_conf(
    profiles_json: str,
    registry_uri: str,
    repository_name: str,
    external_host: str = "127.0.0.1",
    external_ip: str = "127.0.0.1"
) -> str:
    """
    Generate containers.conf content from profiles and registry info.
    
    Args:
        profiles_json: JSON string of CONTAINER_IMAGE_PROFILES_JSON
        registry_uri: ECR registry URI (e.g., 618246141311.dkr.ecr.ap-southeast-1.amazonaws.com)
        repository_name: ECR repository name (e.g., ai-splunk-ecr)
        external_host: External hostname/IP for external URLs
        external_ip: External IP for external URLs
    
    Returns:
        containers.conf content as string
    """
    profiles = json.loads(profiles_json)
    
    if not isinstance(profiles, list):
        raise ValueError("CONTAINER_IMAGE_PROFILES_JSON must be a JSON array")
    
    conf_content = "[default]\ncluster = docker\n\n"
    
    for profile in profiles:
        if not isinstance(profile, dict):
            continue
        
        name = profile.get('name', '').strip()
        source_image = profile.get('source_image', '').strip()
        mode = profile.get('mode', 'DEV').strip()
        host_port = profile.get('host_port', 5000)
        runtime = profile.get('runtime', 'None').strip()
        
        if not name or not source_image:
            continue
        
        # Parse source image: e.g., "splunk/mltk-container-ubi-llm-rag:5.2.3"
        # to extract image name and tag
        if '/' in source_image:
            image_part = source_image.rsplit('/', 1)[-1]
        else:
            image_part = source_image
        
        # Split image and tag
        if ':' in image_part:
            image_name, image_tag = image_part.rsplit(':', 1)
        else:
            image_name = image_part
            image_tag = 'latest'
        
        # Construct full ECR URI
        full_ecr_uri = f"{registry_uri}/{repository_name}/{source_image}"
        
        # Parse ECR URI to get repo, image, tag
        repo, image, tag = parse_ecr_uri(full_ecr_uri)
        
        # Build section
        conf_content += f"[__{name}__]\n"
        conf_content += f"cluster = docker\n"
        conf_content += f"id = \n"
        conf_content += f"repo = {repo}\n"
        conf_content += f"image = {image}\n"
        conf_content += f"tag = {image_name}\n"
        conf_content += f"mode = {mode}\n"
        conf_content += f"api_url_external = https://{external_ip}:{host_port}\n"
        conf_content += f"runtime = {runtime}\n"
        conf_content += f"api_url = https://127.0.0.1:{host_port}\n"
        conf_content += "\n"
    
    return conf_content


def main():
    """Read from environment and generate containers.conf"""
    profiles_json = os.getenv('CONTAINER_IMAGE_PROFILES_JSON', '')
    registry_uri = os.getenv('ECR_REGISTRY_URI', '')
    repository_name = os.getenv('ECR_REPOSITORY_NAME', '')
    external_host = os.getenv('MLTK_CONTAINER_EXTERNAL_HOST', '127.0.0.1')
    
    if not profiles_json:
        print("Error: CONTAINER_IMAGE_PROFILES_JSON not set", file=sys.stderr)
        sys.exit(1)
    
    if not registry_uri:
        print("Error: ECR_REGISTRY_URI not set", file=sys.stderr)
        sys.exit(1)
    
    if not repository_name:
        print("Error: ECR_REPOSITORY_NAME not set", file=sys.stderr)
        sys.exit(1)
    
    try:
        conf = generate_containers_conf(
            profiles_json,
            registry_uri,
            repository_name,
            external_host=external_host,
            external_ip=external_host
        )
        print(conf)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
