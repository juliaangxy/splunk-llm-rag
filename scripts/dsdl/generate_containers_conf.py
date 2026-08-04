#!/usr/bin/env python3
"""Generate containers.conf from CONTAINER_IMAGE_PROFILES_JSON and ECR info."""

import json
import os
import re
import sys
from pathlib import Path


def parse_ecr_uri(full_uri):
	"""Parse ECR URI: registry/repository/image:tag -> (repo, image, tag)"""
	parts = full_uri.split('/', 1)
	repo = parts[0]
	if len(parts) < 2:
		return repo, full_uri, full_uri
	remainder = parts[1]
	path_parts = remainder.rsplit('/', 1)
	image_with_tag = path_parts[-1]
	if ':' in image_with_tag:
		image_name, _ = image_with_tag.rsplit(':', 1)
	else:
		image_name = image_with_tag
	return repo, image_with_tag, image_name


def extract_docker_host(docker_uri):
	"""Extract host from docker URI: tcp://127.0.0.1:2375 -> 127.0.0.1"""
	# Remove protocol and extract host before port
	match = re.search(r'://([^:]+)', docker_uri)
	if match:
		return match.group(1)
	return '127.0.0.1'


def generate_containers_conf(profiles_json, registry_uri, repo_name, dsdl_docker_host, output_path):
	"""Generate containers.conf with [default] and [__dev__] sections."""
	try:
		profiles = json.loads(profiles_json)
	except json.JSONDecodeError as e:
		print(f"Error parsing CONTAINER_IMAGE_PROFILES_JSON: {e}", file=sys.stderr)
		sys.exit(1)

	if not isinstance(profiles, list):
		print("Error: CONTAINER_IMAGE_PROFILES_JSON must be a JSON array", file=sys.stderr)
		sys.exit(1)

	# Extract host from DSDL_DOCKER_HOST for api_url
	external_host = extract_docker_host(dsdl_docker_host) if dsdl_docker_host else '127.0.0.1'

	lines = ['[default]', 'cluster = docker', '']

	# Use first profile for [__dev__] section
	for profile in profiles:
		if not isinstance(profile, dict):
			continue
		source_image = str(profile.get('image') or profile.get('source_image') or '').strip()
		host_port = profile.get('host_port')
		if not source_image or not host_port:
			continue

		mode = str(profile.get('mode') or 'DEV').strip()
		runtime = str(profile.get('runtime') or 'None').strip()

		if registry_uri and repo_name:
			full_ecr_uri = f'{registry_uri}/{repo_name}/{source_image}'
			repo, image, tag = parse_ecr_uri(full_ecr_uri)
		else:
			repo = ''
			image = source_image
			tag = source_image.rsplit(':', 1)[0] if ':' in source_image else source_image

		lines.extend([
			'[__dev__]',
			'cluster = docker',
			'id = ',
		])
		if repo:
			lines.append(f'repo = {repo}')
		lines.extend([
			f'image = {image}',
			f'tag = {tag}',
			f'mode = {mode}',
			f'api_url_external = https://{external_host}:{host_port}',
			f'runtime = {runtime}',
			f'api_url = https://{external_host}:{host_port}',
		])
		break

	Path(output_path).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
	profiles_json = os.getenv('CONTAINER_IMAGE_PROFILES_JSON', '')
	registry_uri = os.getenv('ECR_REGISTRY_URI', '')
	repo_name = os.getenv('ECR_REPOSITORY_NAME', '')
	dsdl_docker_host = os.getenv('DSDL_DOCKER_HOST', 'tcp://127.0.0.1:2375')
	output_path = os.getenv('CONTAINERS_CONF_PATH', '')

	if not output_path:
		print("Error: CONTAINERS_CONF_PATH not set", file=sys.stderr)
		sys.exit(1)

	generate_containers_conf(profiles_json, registry_uri, repo_name, dsdl_docker_host, output_path)
