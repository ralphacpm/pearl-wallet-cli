#!/bin/bash
# pearl_otc.sh — Pearl OTC CLI: snipe bids or create listings
set -uo pipefail

API="https://api.pearl-otc.com"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
CONFIG="$HOME/.pearl_otc.conf"

# ── helpers ──────────────────────────────────────────────────────────────────

red()   { echo -e "\033[1;31m$*\033[0m"; }
green() { echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

load_config() {
    if [[ -f "$CONFIG" ]]; then source "$CONFIG"; fi
}

save_config() {
    cat > "$CONFIG" <<EOF
TOKEN="$TOKEN"
DEFAULT_SELLER_USDC="$DEFAULT_SELLER_USDC"
DEFAULT_SELLER_USDC_CHAIN="$DEFAULT_SELLER_USDC_CHAIN"
DEFAULT_SELLER_PRL_REFUND="$DEFAULT_SELLER_PRL_REFUND"
DEFAULT_INTERVAL="$INTERVAL"
EOF
    chmod 600 "$CONFIG"
}

prompt() {
    local var="$1" msg="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        read -rp "$(bold "$msg") [$default]: " val
        val="${val:-$default}"
    else
        read -rp "$(bold "$msg"): " val
        while [[ -z "$val" ]]; do
            red "  Required."
            read -rp "$(bold "$msg"): " val
        done
    fi
    printf -v "$var" '%s' "$val"
}

prompt_optional() {
    local var="$1" msg="$2" default="${3:-}"
    read -rp "$(bold "$msg") [${default:-none}]: " val
    val="${val:-$default}"
    printf -v "$var" '%s' "$val"
}

# ── defaults ──────────────────────────────────────────────────────────────────

DEFAULT_SELLER_USDC="${DEFAULT_SELLER_USDC:-}"
DEFAULT_SELLER_USDC_CHAIN="${DEFAULT_SELLER_USDC_CHAIN:-ARBITRUM}"
DEFAULT_SELLER_PRL_REFUND="${DEFAULT_SELLER_PRL_REFUND:-}"
DEFAULT_INTERVAL="${DEFAULT_INTERVAL:-15}"
TOKEN="${TOKEN:-}"
INTERVAL="$DEFAULT_INTERVAL"

load_config

# ── auth ──────────────────────────────────────────────────────────────────────

if [[ -z "$TOKEN" ]]; then
    prompt TOKEN "Paste your Bearer token (from browser DevTools → Authorization header)"
    TOKEN="${TOKEN#Bearer }"
fi
TOKEN_HEADER="Bearer ${TOKEN#Bearer }"

validate_token() {
    ME=$(curl -s -H "Authorization: $TOKEN_HEADER" -H "User-Agent: $UA" "$API/auth/me")
    USERNAME=$(echo "$ME" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('username',''))" 2>/dev/null)
    [[ -n "$USERNAME" ]]
}

refresh_token() {
    echo
    yellow "Token expired or invalid. Paste a fresh one (DevTools → Authorization header)."
    prompt TOKEN "Fresh Bearer token"
    TOKEN="${TOKEN#Bearer }"
    TOKEN_HEADER="Bearer ${TOKEN#Bearer }"
    if validate_token; then
        green "Re-authenticated as: $USERNAME"
        save_config
        return 0
    else
        red "Token still invalid — cannot continue."
        return 1
    fi
}

if ! validate_token; then
    red "Token invalid or expired."
    refresh_token || exit 1
fi
green "Logged in as: $USERNAME"

# ── shared API helpers ────────────────────────────────────────────────────────

is_locked() {
    echo "$1" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print('yes' if 'open trade' in str(d.get('detail','')) else 'no')
except: print('no')
" 2>/dev/null
}

is_unauthorized() {
    echo "$1" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    detail=str(d.get('detail','')).lower()
    code=d.get('status_code', d.get('code', 0))
    print('yes' if any(w in detail for w in ['unauthorized','invalid token','expired','not authenticated']) or str(code)=='401' else 'no')
except: print('no')
" 2>/dev/null
}

# ── watch command ─────────────────────────────────────────────────────────────

do_watch() {
    echo
    prompt MIN_PRICE     "Minimum price you'll accept (USDC/PRL)"
    prompt PRL_AMOUNT    "PRL amount to sell"
    prompt INTERVAL      "Poll interval in seconds"                  "${DEFAULT_INTERVAL:-15}"

    echo
    bold "Your receiving addresses:"
    prompt SELLER_USDC_ADDR  "  USDC receive address (EVM)"            "${DEFAULT_SELLER_USDC:-}"
    prompt SELLER_USDC_CHAIN "  Chain (ARBITRUM / BASE / ETHEREUM)"    "${DEFAULT_SELLER_USDC_CHAIN:-}"
    prompt SELLER_PRL_REFUND "  PRL refund address (if trade cancels)"  "${DEFAULT_SELLER_PRL_REFUND:-}"

    DEFAULT_SELLER_USDC="$SELLER_USDC_ADDR"
    DEFAULT_SELLER_USDC_CHAIN="$SELLER_USDC_CHAIN"
    DEFAULT_SELLER_PRL_REFUND="$SELLER_PRL_REFUND"
    save_config

    find_best_bid() {
        curl -s -H "User-Agent: $UA" "$API/offers?side=BUY_PRL" | python3 -c "
import json, sys
data = json.load(sys.stdin)
min_price = float('$MIN_PRICE')
prl_amount = float('$PRL_AMOUNT')
candidates = [
    o for o in data
    if o['status'] == 'ACTIVE'
    and float(o['usdc_per_prl']) >= min_price
    and float(o['prl_min_trade']) <= prl_amount <= float(o['prl_max_trade'])
    and float(o['prl_remaining']) >= prl_amount
]
if not candidates:
    print('null')
else:
    best = max(candidates, key=lambda o: float(o['usdc_per_prl']))
    print(json.dumps(best))
" 2>/dev/null
    }

    try_trade() {
        local offer_id="$1"
        local body
        body=$(python3 -c "
import json
print(json.dumps({
    'offer_id': int('$offer_id'),
    'prl_amount': float('$PRL_AMOUNT'),
    'seller_usdc_address': '$SELLER_USDC_ADDR',
    'seller_prl_refund_address': '$SELLER_PRL_REFUND',
    'usdc_chain': '$SELLER_USDC_CHAIN'
}))
")
        curl -s -X POST \
            -H "Authorization: $TOKEN_HEADER" \
            -H "User-Agent: $UA" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$API/trades"
    }

    echo
    bold "Watching for BUY bids >= \$$MIN_PRICE/PRL for $PRL_AMOUNT PRL..."
    echo "Poll interval: ${INTERVAL}s. Ctrl+C to stop."
    echo

    local POLL_COUNT=0
    local TOKEN_CHECK_EVERY=$(( 600 / INTERVAL > 0 ? 600 / INTERVAL : 1 ))

    while true; do
        POLL_COUNT=$(( POLL_COUNT + 1 ))
        if (( POLL_COUNT % TOKEN_CHECK_EVERY == 0 )); then
            if ! validate_token; then refresh_token || exit 1; fi
        fi

        local BID; BID=$(find_best_bid)

        if [[ "$BID" == "null" || -z "$BID" ]]; then
            echo -ne "\r[$(date '+%H:%M:%S')] No qualifying bids (need >= \$$MIN_PRICE, amount $PRL_AMOUNT)..."
            sleep "$INTERVAL"
            continue
        fi

        local OFFER_ID PRICE USDC_TOTAL
        OFFER_ID=$(echo "$BID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        PRICE=$(echo "$BID"    | python3 -c "import json,sys; print(json.load(sys.stdin)['usdc_per_prl'])")
        USDC_TOTAL=$(python3 -c "print(round(float('$PRL_AMOUNT') * float('$PRICE'), 2))")

        local QUICK_RETRIES=0
        while true; do
            echo -ne "\r[$(date '+%H:%M:%S')] Found bid #$OFFER_ID @ \$$PRICE — trying...          "

            local RESP; RESP=$(try_trade "$OFFER_ID")

            if [[ "$(is_unauthorized "$RESP")" == "yes" ]]; then
                echo; refresh_token || exit 1; break
            fi

            if [[ "$(is_locked "$RESP")" == "yes" ]]; then
                local BLOCKING
                BLOCKING=$(echo "$RESP" | python3 -c "
import json,sys,re
try:
    m=re.search(r'#(\d+)', json.load(sys.stdin).get('detail',''))
    print(m.group(1) if m else '?')
except: print('?')
" 2>/dev/null)
                QUICK_RETRIES=$(( QUICK_RETRIES + 1 ))
                if (( QUICK_RETRIES < 5 )); then
                    echo -ne "\r[$(date '+%H:%M:%S')] Bid #$OFFER_ID locked by trade #$BLOCKING — quick retry ${QUICK_RETRIES}/5 in 2s..."
                    sleep 2; continue
                else
                    echo -ne "\r[$(date '+%H:%M:%S')] Bid #$OFFER_ID still locked after 5 retries — re-polling in ${INTERVAL}s..."
                    sleep "$INTERVAL"; break
                fi
            fi

            local TRADE_ID DEPOSIT_ADDR FEE_PRL
            TRADE_ID=$(echo "$RESP"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
            DEPOSIT_ADDR=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deposit_address',''))" 2>/dev/null)
            FEE_PRL=$(echo "$RESP"     | python3 -c "import json,sys; print(json.load(sys.stdin).get('fee_prl',''))" 2>/dev/null)

            if [[ -n "$TRADE_ID" ]]; then
                echo
                green "=========================================="
                green "  TRADE POSTED!"
                green "  Trade  : #$TRADE_ID"
                green "  Offer  : #$OFFER_ID"
                green "  Amount : $PRL_AMOUNT PRL @ \$$PRICE = ~\$$USDC_TOTAL USDC"
                [[ -n "$FEE_PRL" ]]      && green "  Fee    : $FEE_PRL PRL"
                [[ -n "$DEPOSIT_ADDR" ]] && green "  Send PRL to: $DEPOSIT_ADDR"
                green "  URL    : https://pearl-otc.com/trades/$TRADE_ID"
                green "=========================================="
                notify-send "Pearl OTC Trade Posted!" "#$TRADE_ID — send $PRL_AMOUNT PRL to $DEPOSIT_ADDR" 2>/dev/null || true
                exit 0
            else
                echo
                yellow "Bid #$OFFER_ID failed (non-lock error):"
                echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
                echo "Continuing to watch..."
                sleep "$INTERVAL"; break
            fi
        done
    done
}

# ── create-listing command ────────────────────────────────────────────────────

do_create_listing() {
    # Auto-fetch default USDC address (no prompt needed)
    ADDRS=$(curl -s -H "Authorization: $TOKEN_HEADER" -H "User-Agent: $UA" "$API/usdc-addresses")
    ADDR_ID=$(echo "$ADDRS" | python3 -c "
import json,sys
addrs=json.load(sys.stdin)
default=[a for a in addrs if a.get('is_default')]
print(default[0]['id'] if default else (addrs[0]['id'] if addrs else ''))
" 2>/dev/null)
    [[ -z "$ADDR_ID" ]] && { red "No saved USDC addresses found on your account."; exit 1; }

    # Use saved PRL refund address; prompt once if not set
    PRL_REFUND="${DEFAULT_SELLER_PRL_REFUND:-}"
    if [[ -z "$PRL_REFUND" ]]; then
        prompt PRL_REFUND "Your PRL refund address (for cancelled trades)"
        DEFAULT_SELLER_PRL_REFUND="$PRL_REFUND"
        save_config
    fi

    echo
    prompt PRL_AMOUNT "PRL amount"
    prompt PRICE      "Price (USDC per PRL)"

    BODY=$(python3 -c "
import json
print(json.dumps({
    'side': 'SELL_PRL',
    'prl_amount': float('$PRL_AMOUNT'),
    'usdc_per_prl': float('$PRICE'),
    'usdc_address_id': int('$ADDR_ID'),
    'seller_prl_refund_address': '$PRL_REFUND',
    'is_private': False,
}))")

    RESP=$(curl -s -X POST \
        -H "Authorization: $TOKEN_HEADER" \
        -H "User-Agent: $UA" \
        -H "Content-Type: application/json" \
        -d "$BODY" \
        "$API/offers")

    if [[ "$(is_unauthorized "$RESP")" == "yes" ]]; then
        refresh_token || exit 1
        echo "Token refreshed — please re-run to post the listing."
        exit 1
    fi

    LISTING_ID=$(echo "$RESP" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('id',''))
except: print('')
" 2>/dev/null)

    if [[ -n "$LISTING_ID" ]]; then
        echo
        green "=========================================="
        green "  LISTING CREATED!"
        green "  Offer  : #$LISTING_ID"
        green "  Amount : $PRL_AMOUNT PRL @ \$$PRICE USDC/PRL"
        green "  URL    : https://pearl-otc.com/offers/$LISTING_ID"
        green "=========================================="
        notify-send "Pearl OTC Listing Created!" "#$LISTING_ID — $PRL_AMOUNT PRL @ \$$PRICE" 2>/dev/null || true
    else
        red "Failed to create listing:"
        echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
        exit 1
    fi
}

# ── reprice command ───────────────────────────────────────────────────────────

do_reprice() {
    local offer_id="${1?Usage: pearl_otc.sh reprice <offer_id> <new_price>}"
    local new_price="${2?Usage: pearl_otc.sh reprice <offer_id> <new_price>}"

    # Fetch the offer from /offers/mine
    local offer
    offer=$(curl -s -H "Authorization: $TOKEN_HEADER" -H "User-Agent: $UA" "$API/offers/mine" | python3 -c "
import json,sys
offers=json.load(sys.stdin)
match=[o for o in offers if str(o['id'])=='$offer_id']
print(json.dumps(match[0]) if match else 'null')
" 2>/dev/null)

    [[ "$offer" == "null" || -z "$offer" ]] && { red "Offer #$offer_id not found in your offers."; exit 1; }

    local status side remaining min_trade max_trade prl_refund notes is_private old_price
    status=$(   echo "$offer" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    side=$(     echo "$offer" | python3 -c "import json,sys; print(json.load(sys.stdin)['side'])")
    remaining=$(echo "$offer" | python3 -c "import json,sys; print(json.load(sys.stdin)['prl_remaining'])")
    min_trade=$(echo "$offer" | python3 -c "import json,sys; print(json.load(sys.stdin)['prl_min_trade'])")
    max_trade=$(echo "$offer" | python3 -c "import json,sys; o=json.load(sys.stdin); print(min(float(o['prl_max_trade']),float(o['prl_remaining'])))")
    prl_refund=$(echo "$offer"| python3 -c "import json,sys; print(json.load(sys.stdin)['seller_prl_refund_address'])")
    notes=$(    echo "$offer" | python3 -c "import json,sys; print(json.load(sys.stdin)['notes'] or '')")
    is_private=$(echo "$offer"| python3 -c "import json,sys; print(str(json.load(sys.stdin)['is_private']).lower())")
    old_price=$(echo "$offer" | python3 -c "import json,sys; print(json.load(sys.stdin)['usdc_per_prl'])")

    if [[ "$status" != "ACTIVE" ]]; then
        red "Offer #$offer_id is $status — can only reprice ACTIVE offers."
        exit 1
    fi

    # Get default usdc_address_id
    local addr_id
    addr_id=$(curl -s -H "Authorization: $TOKEN_HEADER" -H "User-Agent: $UA" "$API/usdc-addresses" | python3 -c "
import json,sys
addrs=json.load(sys.stdin)
default=[a for a in addrs if a.get('is_default')]
print(default[0]['id'] if default else (addrs[0]['id'] if addrs else ''))
" 2>/dev/null)
    [[ -z "$addr_id" ]] && { red "No saved USDC addresses found."; exit 1; }

    echo
    bold "Repricing offer #$offer_id"
    echo "  Side      : $side"
    echo "  Amount    : $remaining PRL"
    echo "  Old price : \$$old_price/PRL"
    echo "  New price : \$$new_price/PRL"
    echo
    yellow "WARNING: cancel happens first. If the re-post fails you will have no active listing."
    echo
    read -rp "Confirm? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    # Step 1: cancel
    echo -n "Cancelling #$offer_id..."
    curl -s -X POST -H "Authorization: $TOKEN_HEADER" -H "User-Agent: $UA" "$API/offers/$offer_id/cancel" > /dev/null
    echo " done"

    # Step 2: re-post
    echo -n "Posting new offer at \$$new_price..."
    local body new_id resp
    body=$(python3 -c "
import json
d = {
    'side': '$side',
    'prl_amount': float('$remaining'),
    'usdc_per_prl': float('$new_price'),
    'usdc_address_id': int('$addr_id'),
    'seller_prl_refund_address': '$prl_refund',
    'prl_min_trade': float('$min_trade'),
    'prl_max_trade': float('$max_trade'),
    'is_private': '$is_private' == 'true',
}
if '$notes': d['notes'] = '$notes'
print(json.dumps(d))
")
    resp=$(curl -s -X POST \
        -H "Authorization: $TOKEN_HEADER" \
        -H "User-Agent: $UA" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$API/offers")
    new_id=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

    if [[ -n "$new_id" ]]; then
        echo
        green "=========================================="
        green "  OFFER REPRICED!"
        green "  Cancelled : #$offer_id @ \$$old_price"
        green "  New offer : #$new_id @ \$$new_price"
        green "  Amount    : $remaining PRL"
        green "  URL       : https://pearl-otc.com/offers/$new_id"
        green "=========================================="
    else
        echo
        red "Re-post failed — offer #$offer_id was cancelled but new offer was NOT created!"
        echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
        exit 1
    fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────

CMD="${1:-watch}"
case "$CMD" in
    watch)           do_watch ;;
    create-listing)  do_create_listing ;;
    reprice)         do_reprice "${2:-}" "${3:-}" ;;
    *)
        echo "Usage: pearl_otc.sh [watch|create-listing|reprice]"
        echo "  watch                        — watch for bids and auto-sell (default)"
        echo "  create-listing               — post a new offer on Pearl OTC"
        echo "  reprice <offer_id> <price>   — cancel and re-post offer at new price"
        exit 1 ;;
esac
