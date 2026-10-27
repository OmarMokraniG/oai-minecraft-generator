from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import OpenAI


def create_openai_client(settings):
    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    token_provider = get_bearer_token_provider(
        credential, "https://cognitiveservices.azure.com/.default"
    )
    return OpenAI(
        base_url=f"{settings.endpoint}/openai/v1/",
        api_key=token_provider,
        timeout=240,
        # Retrying image generation can charge for a second image after a timeout.
        max_retries=0,
    )
