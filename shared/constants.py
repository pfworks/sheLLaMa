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

# Amazon Bedrock on-demand pricing (per 1M tokens, us-east-1)
# Claude models: from AWS published pricing (not yet in Pricing API)
# Other models: fetched live from AWS Pricing API, these are static fallbacks
BEDROCK_PRICING_STATIC = {
    'Bedrock Claude Opus 4':      {'input': 15.00, 'output': 75.00},
    'Bedrock Claude 4 Sonnet':    {'input': 3.00,  'output': 15.00},
    'Bedrock Claude 3.5 Sonnet':  {'input': 3.00,  'output': 15.00},
    'Bedrock Claude 3.5 Haiku':   {'input': 0.80,  'output': 4.00},
    'Bedrock Nova Pro':           {'input': 0.80,  'output': 3.20},
    'Bedrock Nova Lite':          {'input': 0.06,  'output': 0.24},
    'Bedrock Nova Micro':         {'input': 0.035, 'output': 0.14},
    'Bedrock Nova Premier':       {'input': 2.50,  'output': 12.50},
    'Bedrock Llama 4 Maverick':   {'input': 0.24,  'output': 0.97},
    'Bedrock Llama 4 Scout':      {'input': 0.17,  'output': 0.66},
    'Bedrock Llama 3.3 70B':      {'input': 0.72,  'output': 0.72},
    'Bedrock DeepSeek R1':        {'input': 1.35,  'output': 5.40},
    'Bedrock Mistral Large 3':    {'input': 0.50,  'output': 1.50},
}

# Models to fetch from AWS Pricing API (model name in API -> display name)
BEDROCK_API_MODELS = {
    'Nova Pro':           'Bedrock Nova Pro',
    'Nova Lite':          'Bedrock Nova Lite',
    'Nova Micro':         'Bedrock Nova Micro',
    'Nova Premier':       'Bedrock Nova Premier',
    'Llama 4 Maverick 17B': 'Bedrock Llama 4 Maverick',
    'Llama 4 Scout 17B':  'Bedrock Llama 4 Scout',
    'Llama 3.3 70B':      'Bedrock Llama 3.3 70B',
    'R1':                 'Bedrock DeepSeek R1',
    'Mistral Large 3':    'Bedrock Mistral Large 3',
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

# Enterprise/subscription AI services (per seat/month pricing)
# These are flat-rate subscriptions, not per-token — we compare by showing
# what the equivalent per-token cost would be at your usage level, and
# what the monthly seat cost would be for your team size.
ENTERPRISE_PRICING = {
    'Microsoft Copilot': {
        'monthly_per_seat': 30.00,
        'description': 'M365 Copilot (GPT-4o)',
        'underlying_model': 'GPT-4o',
        'url': 'https://www.microsoft.com/en-us/microsoft-365/copilot',
    },
    'ChatGPT Team': {
        'monthly_per_seat': 30.00,
        'description': 'ChatGPT Team (GPT-4o, o3)',
        'underlying_model': 'GPT-4o',
        'url': 'https://openai.com/chatgpt/team/',
    },
    'ChatGPT Enterprise': {
        'monthly_per_seat': 60.00,
        'description': 'ChatGPT Enterprise (unlimited GPT-4o, o3, admin)',
        'underlying_model': 'GPT-4o',
        'url': 'https://openai.com/chatgpt/enterprise/',
    },
    'Claude Team': {
        'monthly_per_seat': 30.00,
        'description': 'Claude Team (Sonnet 4, Opus 4)',
        'underlying_model': 'Claude 4 Sonnet',
        'url': 'https://www.anthropic.com/claude/team',
    },
    'Claude Enterprise': {
        'monthly_per_seat': 60.00,
        'description': 'Claude Enterprise (higher limits, SSO, admin)',
        'underlying_model': 'Claude 4 Sonnet',
        'url': 'https://www.anthropic.com/claude/enterprise',
    },
    'Google Gemini Business': {
        'monthly_per_seat': 24.00,
        'description': 'Gemini for Workspace (Gemini 2.5)',
        'underlying_model': 'Gemini 2.5 Pro',
        'url': 'https://workspace.google.com/products/gemini/',
    },
    'Google Gemini Enterprise': {
        'monthly_per_seat': 36.00,
        'description': 'Gemini Enterprise (unlimited, NotebookLM)',
        'underlying_model': 'Gemini 2.5 Pro',
        'url': 'https://workspace.google.com/products/gemini/',
    },
    'Grok (X Premium+)': {
        'monthly_per_seat': 40.00,
        'description': 'X Premium+ (Grok 3, image gen)',
        'underlying_model': 'Grok 3',
        'url': 'https://x.com/premium',
    },
    'Amazon Q Developer Pro': {
        'monthly_per_seat': 19.00,
        'description': 'Amazon Q Developer Pro (code, agents)',
        'underlying_model': 'Bedrock Claude 4 Sonnet',
        'url': 'https://aws.amazon.com/q/developer/',
    },
    'Amazon Q Business Pro': {
        'monthly_per_seat': 20.00,
        'description': 'Amazon Q Business Pro (enterprise search, chat)',
        'underlying_model': 'Bedrock Nova Pro',
        'url': 'https://aws.amazon.com/q/business/',
    },
}

# Cache for live pricing
_cached_pricing = None
_cached_pricing_source = None
_cached_bedrock = None

TEST_PROMPT = "Write a Python function that reads a CSV file and returns the top 5 rows sorted by a given column name. Include error handling and type hints."


def model_size(name):
    """Extract numeric size from model name like qwen2.5-coder:14b -> 14."""
    m = re.search(r':(\d+\.?\d*)b', name)
    return float(m.group(1)) if m else 0


def fetch_bedrock_pricing():
    """Fetch live Bedrock pricing from AWS Pricing API, fall back to static."""
    global _cached_bedrock
    try:
        import subprocess, json
        result = subprocess.run(
            ['aws', 'pricing', 'get-products', '--service-code', 'AmazonBedrock',
             '--region', 'us-east-1', '--filters',
             'Type=TERM_MATCH,Field=regionCode,Value=us-east-1',
             '--output', 'json'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            _cached_bedrock = BEDROCK_PRICING_STATIC
            return _cached_bedrock

        data = json.loads(result.stdout)
        live = {}
        for item_str in data.get('PriceList', []):
            item = json.loads(item_str)
            attrs = item['product']['attributes']
            model = attrs.get('model', '')
            if model not in BEDROCK_API_MODELS:
                continue
            inf_type = attrs.get('inferenceType', '')
            usage = attrs.get('usagetype', '')
            # Skip batch, video, priority, cross-region, flex, etc.
            skip = ['batch', 'video', 'priority', 'cross-region', 'flex', 'audio', 'cache']
            if any(t in inf_type.lower() for t in skip) or any(t in usage.lower() for t in skip):
                continue
            is_input = 'input' in inf_type.lower()
            is_output = 'output' in inf_type.lower()
            if not is_input and not is_output:
                continue
            terms = item.get('terms', {}).get('OnDemand', {})
            for term in terms.values():
                for dim in term.get('priceDimensions', {}).values():
                    price_per_1k = float(dim['pricePerUnit'].get('USD', '0'))
                    if price_per_1k == 0:
                        continue
                    display_name = BEDROCK_API_MODELS[model]
                    if display_name not in live:
                        live[display_name] = {}
                    if is_input:
                        live[display_name]['input'] = price_per_1k * 1000
                    elif is_output:
                        live[display_name]['output'] = price_per_1k * 1000

        # Start with static (has Claude models not in API), overlay live data
        pricing = dict(BEDROCK_PRICING_STATIC)
        for name, prices in live.items():
            if 'input' in prices and 'output' in prices:
                pricing[name] = prices
        _cached_bedrock = pricing
        return pricing
    except Exception:
        _cached_bedrock = BEDROCK_PRICING_STATIC
        return _cached_bedrock


def get_bedrock_pricing():
    """Return cached Bedrock pricing, fetching if needed."""
    if _cached_bedrock is not None:
        return _cached_bedrock
    return fetch_bedrock_pricing()


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
    """Calculate cloud cost estimates for given token counts (includes Bedrock)."""
    pricing, source = get_cloud_pricing()
    bedrock = get_bedrock_pricing()
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
    for name, price in bedrock.items():
        ci = prompt_tokens * price['input'] / 1_000_000
        co = response_tokens * price['output'] / 1_000_000
        costs.append({
            'provider': name,
            'input_cost': round(ci, 8),
            'output_cost': round(co, 8),
            'total_cost': round(ci + co, 8),
        })
    return costs, source


def enterprise_cost_estimates(prompt_tokens, response_tokens, days=30, num_users=1):
    """Calculate enterprise subscription cost comparison.

    Shows monthly seat cost vs equivalent per-token spend for the same usage.
    days: number of days the token counts span (for monthly projection).
    num_users: number of seats to price.
    """
    pricing, _ = get_cloud_pricing()
    bedrock = get_bedrock_pricing()
    all_pricing = {}
    all_pricing.update(pricing)
    all_pricing.update(bedrock)

    # Project tokens to monthly if period != 30 days
    monthly_factor = 30.0 / max(days, 1)
    monthly_prompt = prompt_tokens * monthly_factor
    monthly_response = response_tokens * monthly_factor

    estimates = []
    for name, info in ENTERPRISE_PRICING.items():
        seat_cost = info['monthly_per_seat'] * num_users
        # Calculate equivalent per-token cost using the underlying model's pricing
        underlying = info['underlying_model']
        token_cost = 0.0
        if underlying in all_pricing:
            p = all_pricing[underlying]
            token_cost = (monthly_prompt * p['input'] + monthly_response * p['output']) / 1_000_000
        estimates.append({
            'provider': name,
            'description': info['description'],
            'monthly_per_seat': info['monthly_per_seat'],
            'num_users': num_users,
            'monthly_total': round(seat_cost, 2),
            'equivalent_token_cost': round(token_cost, 4),
            'savings_vs_subscription': round(seat_cost - token_cost, 2) if token_cost > 0 else None,
        })
    return estimates
