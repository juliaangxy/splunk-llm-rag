#!/usr/bin/env python3
"""Generate images.conf from CONTAINER_IMAGE_PROFILES_JSON and ECR info."""

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


def image_to_section_name(image_uri):
	"""Convert image name to section name (e.g., mltk-container-ubi-llm-rag -> ubi_llm_rag)"""
	# Get part after last /
	image_name = image_uri.rsplit('/', 1)[-1]
	# Remove tag if present
	image_name = image_name.split(':')[0]
	# Remove mltk-container- prefix if present
	image_name = re.sub(r'^mltk-container-', '', image_name)
	# Replace - with _
	return image_name.replace('-', '_')


def image_to_title(image_uri):
	"""Convert image name to title"""
	section = image_to_section_name(image_uri)
	return section.replace('_', ' ').title()


def generate_images_conf(profiles_json, registry_uri, repo_name, output_path):
	"""Generate images.conf with dynamic image stanzas."""
	try:
		profiles = json.loads(profiles_json)
	except json.JSONDecodeError as e:
		print(f"Error parsing CONTAINER_IMAGE_PROFILES_JSON: {e}", file=sys.stderr)
		sys.exit(1)

	if not isinstance(profiles, list):
		print("Error: CONTAINER_IMAGE_PROFILES_JSON must be a JSON array", file=sys.stderr)
		sys.exit(1)

	lines = ['[default]', 'cluster = docker', '']

	for profile in profiles:
		if not isinstance(profile, dict):
			continue
		source_image = str(profile.get('image') or profile.get('source_image') or '').strip()
		host_port = profile.get('host_port')
		if not source_image or not host_port:
			continue

		mode = str(profile.get('mode') or 'dev').strip().lower()
		runtime = str(profile.get('runtime') or 'None').strip()

		# Get section name and title from source image
		section_name = image_to_section_name(source_image)
		title = image_to_title(source_image)

		# Build full ECR URI if registry info is available
		if registry_uri and repo_name:
			full_ecr_uri = f'{registry_uri}/{repo_name}/{source_image}'
			repo, image, tag = parse_ecr_uri(full_ecr_uri)
		else:
			repo = ''
			image = repo_name or 'unknown'
			tag = source_image

		# Port mapping: container_port:5000, jupyter_port:8888
		jupyter_port = host_port - 5000 + 8888
		port_map = f'{host_port}:5000,{jupyter_port}:8888'

		lines.extend([
			f'[{section_name}]',
			f'title = {title}',
		])
		if repo:
			lines.extend([
				f'repo = {repo}',
				f'image = {image}',
			])
		lines.extend([
			f'tag = {tag}',
			f'runtime_mode = {mode}',
			f'port_map = {port_map}',
			f'runtime = {runtime}',
			'',
		])

	Path(output_path).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
	profiles_json = os.getenv('CONTAINER_IMAGE_PROFILES_JSON', '')
	registry_uri = os.getenv('ECR_REGISTRY_URI', '')
	repo_name = os.getenv('ECR_REPOSITORY_NAME', '')
	output_path = os.getenv('IMAGES_CONF_PATH', '')

	if not output_path:
		print("Error: IMAGES_CONF_PATH not set", file=sys.stderr)
		sys.exit(1)

	generate_images_conf(profiles_json, registry_uri, repo_name, output_path)
