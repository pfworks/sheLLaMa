"""Shared constants for sheLLaMa CLI and API."""
import re
import requests

# Map display names to OpenRouter model IDs for live pricing lookup
OPENROUTER_MODELS = {
    'Claude 4 Sonnet':    'anthropic/claude-sonnet-4',
    'Claude 4 Haiku':     'anthropic/claude-haiku-4.5',
    'Claude 3.5 Sonnet':  'anthropic/claude-3.5-sonnet',
    'GPT-4o':             'openai/gpt-4o',
    'GPT-4o mini':        'openai/gpt-4o-mini',
    'OpenAI o3':          'openai/o3',
    'OpenAI o4-mini':     'openai/o4-mini',
    'Gemini 2.5 Pro':     'google/gemini-2.5-pro',
    'Gemini 2.5 Flash':   'google/gemini-2.5-flash',
    'Grok 3':             'x-ai/grok-3',
    'Grok 3 mini':        'x-ai/grok-3-mini',
    'Llama 3.1 70B':      'meta-llama/llama-3.1-70b-instruct',
    'Amazon Nova Pro':    'amazon/nova-pro-v1',
    'Amazon Nova Lite':   'amazon/nova-lite-v1',
    'Amazon Nova Micro':  'amazon/nova-micro-v1',
}

# Static fallback pricing (per 1M tokens) — used when OpenRouter is unreachable
CLOUD_PRICING_STATIC = {
    'Claude 4 Sonnet':    {'input': 3.00,  'output': 15.00},
    'Claude 4 Haiku':     {'input': 1.00,  'output': 5.00},
    'Claude 3.5 Sonnet':  {'input': 3.00,  'output': 15.00},
    'GPT-4o':             {'input': 2.50,  'output': 10.00},
    'GPT-4o mini':        {'input': 0.15,  'output': 0.60},
    'OpenAI o3':          {'input': 2.00,  'output': 8.00},
    'OpenAI o4-mini':     {'input': 1.10,  'output': 4.40},
    'Gemini 2.5 Pro':     {'input': 1.25,  'output': 10.00},
    'Gemini 2.5 Flash':   {'input': 0.30,  'output': 2.50},
    'Grok 3':             {'input': 3.00,  'output': 15.00},
    'Grok 3 mini':        {'input': 0.30,  'output': 0.50},
    'Llama 3.1 70B':      {'input': 0.40,  'output': 0.40},
    'Amazon Nova Pro':    {'input': 0.80,  'output': 3.20},
    'Amazon Nova Lite':   {'input': 0.06,  'output': 0.24},
    'Amazon Nova Micro':  {'input': 0.04,  'output': 0.14},
}

# Cache for live pricing
_cached_pricing = None
_cached_pricing_source = None

TEST_PROMPT = "Write a Python function that reads a CSV file and returns the top 5 rows sorted by a given column name. Include error handling and type hints."


def model_size(name):
    """Extract numeric size from model name like qwen2.5-coder:14b -> 14."""
    m = re.search(r':(\d+\.?\d*)b', name)
    return float(m.group(1)) if m else 0


def fetch_cloud_pricing():
    """Fetch live pricing from OpenRouter, fall back to static."""
    global _cached_pricing, _cached_pricing_source
    try:
        resp = requests.get('https://openrouter.ai/api/v1/models', timeout=10)
        data = resp.json().get('data', [])
        # Build lookup by model ID
        by_id = {}
        for m in data:
            p = m.get('pricing', {})
            prompt = float(p.get('prompt', '0'))
            comp = float(p.get('completion', '0'))
            if prompt > 0 or comp > 0:
                by_id[m['id']] = {'input': prompt * 1e6, 'output': comp * 1e6}
        # Map our display names to live prices
        pricing = {}
        for name, or_id in OPENROUTER_MODELS.items():
            if or_id in by_id:
                pricing[name] = by_id[or_id]
            elif name in CLOUD_PRICING_STATIC:
                pricing[name] = CLOUD_PRICING_STATIC[name]
        if pricing:
            _cached_pricing = pricing
            _cached_pricing_source = 'openrouter'
            return pricing
    except Exception:
        pass
    _cached_pricing = CLOUD_PRICING_STATIC
    _cached_pricing_source = 'static'
    return CLOUD_PRICING_STATIC


def get_cloud_pricing():
    """Return cached pricing, fetching if needed."""
    if _cached_pricing is not None:
        return _cached_pricing, _cached_pricing_source
    return fetch_cloud_pricing(), _cached_pricing_source


def cloud_cost_estimates(prompt_tokens, response_tokens):
    """Calculate cloud cost estimates for given token counts."""
    pricing, source = get_cloud_pricing()
    costs = []
    for name, price in pricing.items():
        ci = prompt_tokens * price['input'] / 1_000_000
        co = response_tokens * price['output'] / 1_000_000
        costs.append({
            'provider': name,
            'input_cost': round(ci, 8),
            'output_cost': round(co, 8),
            'total_cost': round(ci + co, 8),
        })
    return costs, source
