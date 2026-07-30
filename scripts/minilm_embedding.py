#!/usr/bin/env python
# minilm_embedding.py

from sentence_transformers import SentenceTransformer
import pandas as pd
import numpy as np

# This structure is required by the Splunk MLTK / DSDL architecture
class SplunkAppCell:
    def __init__(self, settings):
        self.settings = settings
        # Load the model once from the local path provisioned by your IaC
        # This path maps to the volume mounted in your bootstrap.sh script
        self.model = SentenceTransformer('/srv/app/model')

    def init(self, options):
        """Initializes settings passed from the Splunk command options."""
        self.options = options
        return True

    def transform(self, df, options):
        """
        Processes the data stream directly from your SPL query.
        df: The pandas DataFrame sent by Splunk
        options: Arguments passed from SPL (e.g., text_field="error_message")
        """
        # Read the target field name from the SPL command options
        text_field = options.get('text_field', 'text')

        if text_field not in df.columns:
            raise ValueError(f"Field '{text_field}' not found in Splunk search results.")

        # Fill empty fields to prevent transformer errors
        sentences = df[text_field].fillna("").astype(str).tolist()

        # Compute embeddings locally on the CPU
        embeddings = self.model.encode(sentences, show_progress_bar=False)

        # Splunk handles strings or individual multi-value fields better than raw arrays.
        # Convert the float array to a comma-separated string for easy ingestion into Splunk.
        df['vector_embedding'] = [",".join(map(str, vec)) for vec in embeddings]

        return df
