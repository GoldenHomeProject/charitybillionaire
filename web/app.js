// Charity Billionaire — live homepage + deposit/withdraw logic.
// Reads pool figures straight from the on-chain vault (no backend DB) and,
// once a wallet is connected, lets a depositor add/withdraw USDC and see their
// own position. Past drawings are read from the vault's PrizeAwarded events.

const CONFIG = {
  // Base mainnet (chainId 8453).
  chainId: 8453,
  chainIdHex: "0x2105",
  // Public, origin-open Base mainnet endpoint — safe to ship in client JS
  // (no private key to leak). Used for the wallet "add network" params below.
  rpcUrl: "https://mainnet.base.org",
  // Read endpoints, in priority order. The page reads through a FallbackProvider so a
  // single rate-limited (429) / down RPC fails over instead of dropping the whole read to
  // the $0 fallback. All are browser-CORS-friendly public Base endpoints. Any host added
  // here MUST also be in the _headers CSP connect-src, or the browser blocks it.
  rpcUrls: [
    "https://base-rpc.publicnode.com", // fast/reliable primary (~250ms)
    "https://base.drpc.org",           // fast secondary (~220ms)
    "https://mainnet.base.org",        // official, but often rate-limited/slow → not primary
    "https://base.llamarpc.com",       // last-resort fallback
  ],
  contractAddress: "0x3993bD557E0d4a1E5A8Ec09a005E7Eee3E032f70",
  usdcAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  assetDecimals: 6, // USDC has 6 decimals
  deployBlock: 47761940, // vault creation block, for the winners-event scan
  drawWeekday: 4, // 0=Sun ... 4=Thu. Matches the on-chain schedule (Thu 21:00 ET);
  drawHour: 21,   // used only as a degraded fallback — on-chain nextDrawTime is authoritative.
  drawIntervalMs: 7 * 24 * 60 * 60 * 1000,
  // WalletConnect v2 project id (free at https://cloud.reown.com) — adds a "mobile"
  // option so phone wallets connect via QR. Leave "" to hide it; desktop extension
  // wallets (MetaMask, Coinbase Wallet, Rabby, …) keep working via EIP-6963.
  wcProjectId: "",
  // Sanctions screen — comprehensively US-embargoed jurisdictions (OFAC). Matches the
  // PoolTogether posture: block embargoed countries, NO US-state geofencing. Adjust per
  // counsel. Note: Crimea/Donetsk/Luhansk are sub-regions of Ukraine that an ISO country
  // code (UA) can't isolate; the Terms' sanctions/prohibited-persons clause covers those
  // and OFAC-blocked persons. The authoritative block is a Cloudflare WAF country rule;
  // this client check is the in-app notice layer.
  blockedCountries: ["CU", "IR", "KP", "SY"],
  explorer: "https://basescan.org",
  addChainParams: {
    chainId: "0x2105",
    chainName: "Base",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: ["https://mainnet.base.org"],
    blockExplorerUrls: ["https://basescan.org"],
  },
};

const VAULT_ABI = [
  "function projectedPrize() view returns (uint256)",
  "function totalDeposited() view returns (uint256)",
  "function depositorCount() view returns (uint256)",
  "function eligibleTotal() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function currentCharityOrgId() view returns (bytes32)",
  "function nextCharityOrgId() view returns (bytes32)",
  "function nextDrawTime() view returns (uint256)",
  "function lastDrawTime() view returns (uint256)",
  "function deposit(uint256 amount)",
  "function withdraw(uint256 amount)",
  "event PrizeAwarded(address indexed winner, uint256 winnerAmount, address indexed charity, uint256 charityAmount, uint256 companyAmount)",
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

// Honest fallback shown ONLY if the live on-chain read fails (e.g. RPC briefly down).
// This is a live money site, so the fallback must NEVER fabricate a prize/pool — it shows
// the true neutral state (zeros) rather than invented figures that could mislead a visitor.
const FALLBACK = { prize: 0, pool: 0, wallets: 0, currentEin: null, nextEin: null };

// Human-readable registry keyed by IRS EIN. The on-chain rotation stores each charity as
// its EIN encoded to bytes32; the site reads currentCharityOrgId()/nextCharityOrgId(),
// decodes the EIN, and promotes the beneficiary by name. EINs cross-verified
// (ProPublica + Charity Navigator + IRS) — must match the on-chain setCharityRotation list.
const CHARITIES = {
  "95-1831116": { name: "Direct Relief", focus: "Medical & disaster relief",
    blurb: "Delivers medical aid and disaster relief worldwide, directing ~99% of resources to programs.",
    url: "https://www.directrelief.org" },
  "36-3673599": { name: "Feeding America", focus: "Hunger relief",
    blurb: "The largest U.S. hunger-relief network, supplying food banks across the country.",
    url: "https://www.feedingamerica.org" },
  "27-3521132": { name: "World Central Kitchen", focus: "Disaster food relief",
    blurb: "Serves fresh meals to communities in the wake of disasters and crises.",
    url: "https://wck.org" },
  "35-1044585": { name: "St. Jude (ALSAC)", focus: "Childhood cancer",
    blurb: "Funds St. Jude Children's Research Hospital, so families never receive a bill for treatment.",
    url: "https://www.stjude.org" },
  "20-3069841": { name: "Against Malaria Foundation", focus: "Global health",
    blurb: "Funds insecticide-treated bed nets — among the most cost-effective ways to save lives.",
    url: "https://www.againstmalaria.com" },
  "27-1661997": { name: "GiveDirectly", focus: "Direct cash transfers",
    blurb: "Sends money directly to people living in extreme poverty, no strings attached.",
    url: "https://www.givedirectly.org" },
  "22-3936753": { name: "charity: water", focus: "Clean water",
    blurb: "Funds clean and safe drinking-water projects in communities around the world.",
    url: "https://www.charitywater.org" },
  "13-3433452": { name: "Doctors Without Borders", focus: "Medical humanitarian aid",
    blurb: "Provides emergency medical care in conflict zones, disasters, and epidemics worldwide.",
    url: "https://www.doctorswithoutborders.org" },
  "91-1914868": { name: "Habitat for Humanity", focus: "Affordable housing",
    blurb: "Builds and improves homes alongside families in need of decent, affordable housing.",
    url: "https://www.habitat.org" },
  "53-0242652": { name: "The Nature Conservancy", focus: "Environment",
    blurb: "Protects ecologically important lands and waters for nature and people.",
    url: "https://www.nature.org" },
};

// Decode a bytes32 Endaoment org id back to its "XX-XXXXXXX" EIN string (ASCII, null-padded).
function einFromOrgId(b32) {
  if (!b32 || /^0x0*$/.test(b32)) return "";
  let s = "";
  for (let i = 2; i + 1 < b32.length; i += 2) {
    const code = parseInt(b32.slice(i, i + 2), 16);
    if (!code) break;
    s += String.fromCharCode(code);
  }
  return s;
}

function charityInfo(ein) {
  return ein ? CHARITIES[ein] || null : null;
}

const $ = (id) => document.getElementById(id);
const ZERO = "0x0000000000000000000000000000000000000000";

// ---- Number formatting ------------------------------------------------------
const usd = (n, max = 2) =>
  "$" + Number(n).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: max });
const intFmt = (n) => Number(n).toLocaleString("en-US");
const shortAddr = (a) => a.slice(0, 6) + "…" + a.slice(-4);

// ---- ethers loader (cached) -------------------------------------------------
let _ethers = null;
async function eth() {
  // Vendored locally (web/vendor/) so NO third-party CDN sits on the signing path.
  // Update both the file and this version together when bumping ethers.
  if (!_ethers) _ethers = await import("/vendor/ethers-6.16.0.js");
  return _ethers;
}

// ---- Animated counter -------------------------------------------------------
function animateValue(el, to, render, duration = 1400) {
  if (!el) return;
  const from = Number(el.dataset.current || 0);
  const start = performance.now();
  const ease = (t) => 1 - Math.pow(1 - t, 3);
  function frame(now) {
    const t = Math.min(1, (now - start) / duration);
    const v = from + (to - from) * ease(t);
    el.textContent = render(v);
    if (t < 1) requestAnimationFrame(frame);
    else { el.dataset.current = String(to); el.textContent = render(to); }
  }
  requestAnimationFrame(frame);
}

// ---- Countdown clock --------------------------------------------------------
let nextDrawMs = null;
// Minutes that America/New_York is behind UTC at `date` (240 in EDT, 300 in EST).
function etOffsetMinutes(date) {
  const name = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", timeZoneName: "shortOffset" })
    .formatToParts(date).find((p) => p.type === "timeZoneName").value; // e.g. "GMT-4"
  const m = /GMT([+-]\d+)(?::(\d+))?/.exec(name);
  return m ? -(parseInt(m[1], 10) * 60 + (m[1].startsWith("-") ? -1 : 1) * (parseInt(m[2] || "0", 10))) : 240;
}
// Fallback only — the authoritative time is the on-chain nextDrawTime (set by loadLive).
// Compute the next Thursday 21:00 *Eastern* as a real UTC instant, DST-correct, instead of
// using the visitor's local 9 PM (which would be off by hours outside ET).
function computeNextDrawFromCadence() {
  const now = new Date();
  const offNow = etOffsetMinutes(now);
  // Shift into ET wall-clock space so UTC getters read Eastern calendar fields.
  const etNow = new Date(now.getTime() - offNow * 60000);
  const d = new Date(etNow);
  d.setUTCHours(CONFIG.drawHour, 0, 0, 0);
  let delta = (CONFIG.drawWeekday - d.getUTCDay() + 7) % 7;
  if (delta === 0 && d.getTime() <= etNow.getTime()) delta = 7;
  d.setUTCDate(d.getUTCDate() + delta);
  // Convert the ET wall-clock target back to a true UTC instant, using the offset that
  // applies *at the target* (handles a DST change between now and that Thursday).
  const offTarget = etOffsetMinutes(new Date(d.getTime() + offNow * 60000));
  return d.getTime() + offTarget * 60000;
}
function tickClock() {
  if (nextDrawMs == null) nextDrawMs = computeNextDrawFromCadence();
  const pad = (n) => String(n).padStart(2, "0");
  const remaining = nextDrawMs - Date.now();
  if (remaining <= 0) {
    // Draw is due but not yet recorded on-chain (keeper hasn't fired, or loadLive hasn't
    // refreshed the new nextDrawTime yet). Show a settled 00:00:00 rather than inventing a
    // fake ~7-day countdown; loadLive will advance nextDrawMs once the draw lands.
    ["cd-d", "cd-h", "cd-m", "cd-s"].forEach((id) => { if ($(id)) $(id).textContent = "00"; });
    return;
  }
  const s = Math.floor(remaining / 1000);
  if ($("cd-d")) $("cd-d").textContent = pad(Math.floor(s / 86400));
  if ($("cd-h")) $("cd-h").textContent = pad(Math.floor((s % 86400) / 3600));
  if ($("cd-m")) $("cd-m").textContent = pad(Math.floor((s % 3600) / 60));
  if ($("cd-s")) $("cd-s").textContent = pad(s % 60);
}

// ---- Public read provider ---------------------------------------------------
let _readCtx = null;
async function readVault() {
  if (_readCtx) return _readCtx; // build the provider once; loadLive/loadWinners/loadPosition share it
  const { JsonRpcProvider, FallbackProvider, Network, Contract } = await eth();
  const net = Network.from(CONFIG.chainId); // pin chainId 8453 — no eth_chainId re-probe
  // batchMaxCount: 1 — the public Base RPC mangles JSON-RPC batch responses (returns results
  // out of order / drops ids), which made ethers decode an empty 0x for one call in a
  // Promise.all and surface a bogus CALL_EXCEPTION. One eth_call per request is correct.
  const backends = CONFIG.rpcUrls.map((url, i) => ({
    provider: new JsonRpcProvider(url, net, { staticNetwork: true, batchMaxCount: 1 }),
    priority: i + 1,   // try in listed order
    stallTimeout: 700, // ms before failing over to the next backend (keeps first paint snappy)
    weight: 1,
  }));
  // quorum 1 → first successful backend wins; a 429/timeout on one fails over to the next,
  // so a single flaky public RPC can't drop the read to the $0 fallback.
  const provider = backends.length > 1
    ? new FallbackProvider(backends, net, { quorum: 1 })
    : backends[0].provider;
  _readCtx = { provider, vault: new Contract(CONFIG.contractAddress, VAULT_ABI, provider) };
  return _readCtx;
}

async function loadLive() {
  if (!CONFIG.contractAddress) return null;
  try {
    const { formatUnits } = await eth();
    const { vault } = await readVault();
    const [prize, pool, wallets, curOrg, nextOrg, nextDraw] = await Promise.all([
      vault.projectedPrize(), vault.totalDeposited(), vault.depositorCount(),
      vault.currentCharityOrgId(), vault.nextCharityOrgId(), vault.nextDrawTime(),
    ]);
    const dec = CONFIG.assetDecimals;
    // Authoritative: the contract schedules each draw for Thursday 21:00 ET (DST-aware).
    nextDrawMs = Number(nextDraw) * 1000;
    return {
      prize: Number(formatUnits(prize, dec)),
      pool: Number(formatUnits(pool, dec)),
      wallets: Number(wallets),
      currentEin: einFromOrgId(curOrg),
      nextEin: einFromOrgId(nextOrg),
    };
  } catch (err) {
    console.warn("[CB] live read failed, showing demo figures:", err);
    return null;
  }
}

function paint(data) {
  animateValue($("prizeValue"), data.prize, (v) => usd(v, 2));
  animateValue($("poolValue"), data.pool, (v) => usd(v, 0));
  animateValue($("walletsValue"), data.wallets, (v) => intFmt(Math.round(v)));
  paintCharity(data);
}

// Promote this week's beneficiary: resolve the on-chain address to a real name/blurb,
// surface it in the hero ribbon + ledger stat + the featured charity card, and show the
// live gift it will receive (5% of the interest, i.e. 1/18 of the 90% prize figure).
function paintCharity(data) {
  const info = charityInfo(data.currentEin);
  const name = info?.name || (data.currentEin ? `EIN ${data.currentEin}` : "To be announced");
  const announced = Boolean(info || data.currentEin);

  if ($("charityValue")) $("charityValue").textContent = name;
  if ($("charityName")) $("charityName").textContent = name;

  // Hero ribbon — promotes the charity at the top of the page.
  if ($("heroCharityName")) $("heroCharityName").textContent = name;
  if ($("heroCharity")) $("heroCharity").hidden = !announced;

  // Focus tag + blurb in the featured card.
  if ($("charityFocus")) {
    $("charityFocus").textContent = info?.focus || "";
    $("charityFocus").hidden = !info?.focus;
  }
  if ($("charityBlurb") && info?.blurb) $("charityBlurb").textContent = info.blurb;

  // Live gift to this week's charity = 5% of interest = prize * 5/90.
  if ($("charityGift") && typeof data.prize === "number") {
    $("charityGift").textContent = usd((data.prize * 5) / 90, 2);
  }

  // Link out to this week's charity site (from the vetted registry only).
  if ($("charityLink")) {
    if (info?.url) { $("charityLink").href = info.url; $("charityLink").hidden = false; }
    else $("charityLink").hidden = true;
  }

  // Next week's beneficiary — the rotation is deterministic, so it's known in advance.
  const nextInfo = charityInfo(data.nextEin);
  if ($("nextCharityName")) {
    $("nextCharityName").textContent = nextInfo?.name || (data.nextEin ? `EIN ${data.nextEin}` : "—");
  }
}

async function refresh() {
  const live = await loadLive();
  paint(live || FALLBACK);
  if (account) loadPosition();
}

// ---- Wallet / network -------------------------------------------------------
let account = null;
let signer = null;
let injected = null; // the EIP-1193 provider the user chose (MetaMask, Coinbase, …)

// EIP-6963: discover every injected wallet, not just window.ethereum, so users
// can connect MetaMask, Coinbase Wallet, Rabby, etc. and pick which one.
const wallets = new Map(); // rdns -> { info, provider }
window.addEventListener("eip6963:announceProvider", (e) => {
  const d = e.detail;
  if (d && d.info && d.provider) wallets.set(d.info.rdns, d);
});
window.dispatchEvent(new Event("eip6963:requestProvider"));

function listWallets() {
  const found = [...wallets.values()];
  if (found.length) return found;
  // Fallback for wallets that only expose the legacy window.ethereum.
  if (window.ethereum) {
    const providers = window.ethereum.providers || [window.ethereum];
    return providers.map((p) => ({
      info: { name: p.isCoinbaseWallet ? "Coinbase Wallet" : p.isMetaMask ? "MetaMask" : "Browser Wallet", rdns: "injected", icon: "" },
      provider: p,
    }));
  }
  return [];
}

// All connectable wallets: injected (EIP-6963) extensions + WalletConnect for mobile.
// Each option exposes an async get() returning an EIP-1193 provider.
function walletOptions() {
  window.dispatchEvent(new Event("eip6963:requestProvider"));
  const opts = listWallets().map((w) => ({
    name: w.info.name, icon: w.info.icon, get: () => Promise.resolve(w.provider),
  }));
  if (CONFIG.wcProjectId) {
    opts.push({ name: "WalletConnect (mobile)", icon: "", get: wcConnect });
  }
  return opts;
}

function chooseWallet() {
  const opts = walletOptions();
  if (opts.length === 0) return Promise.resolve(null);
  if (opts.length === 1) return opts[0].get();
  return new Promise((resolve) => showWalletPicker(opts, resolve));
}

// Lazy-load WalletConnect v2 and open its QR modal so phone wallets (MetaMask,
// Coinbase Wallet, Rainbow, …) can connect. Returns an EIP-1193 provider that
// plugs into the same flow as injected wallets, or null if the user cancels.
let _wc = null;
async function wcConnect() {
  try {
    if (!_wc) {
      // NOTE: still loaded from CDN. Our CSP (web/_headers) pins script-src to 'self',
      // so this import only works once WalletConnect is vendored locally (a bundler
      // step) and the CSP/connect-src are extended for the WC relay. wcProjectId stays
      // empty until then, so this path is inert in production.
      const { EthereumProvider } = await import("https://esm.sh/@walletconnect/ethereum-provider@2.23.9");
      _wc = await EthereumProvider.init({
        projectId: CONFIG.wcProjectId,
        chains: [CONFIG.chainId],
        optionalChains: [CONFIG.chainId],
        showQrModal: true,
        metadata: {
          name: "Charity Billionaire",
          description: "A no-lose charity prize draw.",
          url: location.origin,
          icons: [location.origin + "/assets/monogram.svg"],
        },
      });
    }
    await _wc.enable(); // opens the QR modal and establishes the session
    return _wc;
  } catch (err) {
    console.warn("[CB] WalletConnect connect failed/cancelled:", err);
    return null;
  }
}

function showWalletPicker(opts, resolve) {
  const overlay = document.createElement("div");
  overlay.className = "wallet-picker";
  const card = document.createElement("div");
  card.className = "wallet-picker-card";
  const eyebrow = document.createElement("p");
  eyebrow.className = "eyebrow";
  eyebrow.textContent = "Connect a Wallet";
  const title = document.createElement("h3");
  title.className = "modal-title display small";
  title.textContent = "Choose your wallet";
  const list = document.createElement("div");
  list.className = "wallet-list";
  opts.forEach((o) => {
    const b = document.createElement("button");
    b.className = "wallet-option";
    if (o.icon) { const img = document.createElement("img"); img.src = o.icon; img.alt = ""; b.appendChild(img); }
    const span = document.createElement("span");
    span.textContent = o.name; // textContent: never trust wallet-provided strings as HTML
    b.appendChild(span);
    b.addEventListener("click", async () => { overlay.remove(); resolve(await o.get()); });
    list.appendChild(b);
  });
  const close = document.createElement("button");
  close.className = "modal-close";
  close.textContent = "×";
  close.setAttribute("aria-label", "Close");
  close.addEventListener("click", () => { overlay.remove(); resolve(null); });
  card.append(close, eyebrow, title, list);
  overlay.appendChild(card);
  overlay.addEventListener("click", (e) => { if (e.target === overlay) { overlay.remove(); resolve(null); } });
  document.body.appendChild(overlay);
}

async function ensureNetwork() {
  if (!injected) return false;
  const current = await injected.request({ method: "eth_chainId" });
  if (current === CONFIG.chainIdHex) return true;
  try {
    await injected.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CONFIG.chainIdHex }] });
    return true;
  } catch (err) {
    if (err && err.code === 4902) {
      await injected.request({ method: "wallet_addEthereumChain", params: [CONFIG.addChainParams] });
      return true;
    }
    throw err;
  }
}

let walletEventsAttached = false;
function attachWalletEvents() {
  if (walletEventsAttached || !injected || !injected.on) return;
  injected.on("accountsChanged", () => location.reload());
  injected.on("chainChanged", () => location.reload());
  walletEventsAttached = true;
}

async function connectWallet() {
  if (jurisdictionBlocked) { toast(REGION_MSG, "warn"); return null; }
  const provider = await chooseWallet();
  if (!provider) {
    toast("Install a Web3 wallet such as MetaMask or Coinbase Wallet, then reconnect.", "warn");
    window.open("https://metamask.io/download/", "_blank", "noopener");
    return null;
  }
  injected = provider;
  try {
    const { BrowserProvider } = await eth();
    const accounts = await injected.request({ method: "eth_requestAccounts" });
    const acct = accounts && accounts[0];
    if (!acct) { toast("No wallet account available.", "warn"); injected = null; return null; }
    // Resolve the signer BEFORE committing the global `account`. If the user rejects the
    // Base network switch in ensureNetwork(), this throws and we must NOT be left with a
    // truthy `account` but a null `signer` — that state shows a position yet makes the next
    // deposit build a Contract on a null signer and dead-end.
    await ensureNetwork();
    const bp = new BrowserProvider(injected);
    signer = await bp.getSigner();
    account = acct;
    attachWalletEvents();
    const btn = $("connectBtn");
    if (btn) btn.textContent = shortAddr(account);
    showPosition();
    loadPosition();
    return account;
  } catch (err) {
    console.warn("[CB] wallet connect declined:", err);
    account = null; signer = null; injected = null; // reset any partial connect state
    toast("Wallet connection cancelled.", "warn");
    return null;
  }
}

// ---- Your position ----------------------------------------------------------
function showPosition() { if ($("position")) $("position").hidden = false; }

async function loadPosition() {
  if (!account || !$("position")) return;
  try {
    const { Contract, formatUnits } = await eth();
    const { provider, vault } = await readVault();
    const usdc = new Contract(CONFIG.usdcAddress, ERC20_ABI, provider);
    const [mine, eligible, walletBal] = await Promise.all([
      vault.balanceOf(account), vault.eligibleTotal(), usdc.balanceOf(account),
    ]);
    const dec = CONFIG.assetDecimals;
    const mineN = Number(formatUnits(mine, dec));
    const eligibleN = Number(formatUnits(eligible, dec));
    const walletN = Number(formatUnits(walletBal, dec));
    if ($("posDeposit")) $("posDeposit").textContent = usd(mineN, 2);
    if ($("posWallet")) $("posWallet").textContent = usd(walletN, 2);
    if ($("posOdds")) {
      const odds = eligibleN > 0 ? (mineN / eligibleN) * 100 : 0;
      $("posOdds").textContent = odds > 0 ? odds.toFixed(odds < 1 ? 2 : 1) + "%" : "—";
    }
  } catch (err) {
    console.warn("[CB] position read failed:", err);
  }
}

// ---- Deposit / withdraw modal ----------------------------------------------
let modalMode = "deposit";

function openModal(mode) {
  if (jurisdictionBlocked && mode === "deposit") { toast(REGION_MSG, "warn"); return; }
  modalMode = mode;
  const m = $("txModal");
  if (!m) return;
  m.hidden = false;
  $("modalTitle").textContent = mode === "deposit" ? "Make a Deposit" : "Withdraw";
  $("modalAction").textContent = mode === "deposit" ? "Deposit USDC" : "Withdraw USDC";
  $("modalHint").textContent = mode === "deposit"
    ? "Deposit USDC on the Base network into the shared pool. Every $1 is one equal entry. Withdraw any time."
    : "Withdraw your principal as USDC on Base. Available immediately — no lock-ups.";
  $("modalAmount").value = "";
  setStatus("");
  if (account) loadPosition();
}
function closeModal() { if ($("txModal")) $("txModal").hidden = true; }
function setStatus(msg, type) {
  const s = $("modalStatus");
  if (!s) return;
  s.textContent = msg || "";
  s.className = "modal-status" + (type ? " " + type : "");
}

let txInFlight = false;
async function submitModal() {
  if (txInFlight) return; // guard: a deposit/withdraw is already running (double-click / Enter+click)
  const raw = ($("modalAmount").value || "").trim();
  const amt = Number(raw);
  if (!raw || isNaN(amt) || amt <= 0) { setStatus("Enter an amount greater than zero.", "err"); return; }
  // Whole dollars only: odds are one equal chance per $1, so cents buy nothing. Reject
  // fractional input rather than silently accept a $2.50 that gives no extra chance.
  if (!Number.isInteger(amt)) {
    setStatus(modalMode === "deposit"
      ? "Whole dollars only — each $1 is one equal chance (no cents)."
      : "Whole dollars only (no cents).", "err");
    return;
  }

  // Lock immediately — connectWallet()/approval can block for many seconds while the user
  // signs, and the button must not stay clickable during that window (it would spawn a
  // second concurrent submit → duplicate wallet prompts and a double approve+deposit).
  txInFlight = true;
  $("modalAction").disabled = true;
  try {
    if (!account) { const a = await connectWallet(); if (!a) { setStatus("Connect your wallet to continue.", "err"); return; } }
    try { await ensureNetwork(); } catch { setStatus("Please switch your wallet to Base.", "err"); return; }

    const { Contract, parseUnits, formatUnits } = await eth();
    // parseUnits can throw on malformed input (e.g. too many decimals); inside the try so
    // the user sees a friendly error rather than an unhandled rejection.
    const value = parseUnits(raw, CONFIG.assetDecimals);
    const vault = new Contract(CONFIG.contractAddress, VAULT_ABI, signer);
    if (modalMode === "deposit") {
      const usdc = new Contract(CONFIG.usdcAddress, ERC20_ABI, signer);
      const allowance = await usdc.allowance(account, CONFIG.contractAddress);
      if (allowance < value) {
        setStatus("Approve USDC in your wallet…", "pending");
        const txa = await usdc.approve(CONFIG.contractAddress, value);
        setStatus("Waiting for approval to confirm…", "pending");
        await txa.wait();
      }
      setStatus("Confirm the deposit in your wallet…", "pending");
      const tx = await vault.deposit(value);
      setStatus("Depositing… waiting for confirmation.", "pending");
      await tx.wait();
      setStatus("Deposit confirmed. Welcome to the pool.", "ok");
      toast("Deposit confirmed ✓", "ok");
    } else {
      // Block withdrawing more than your principal client-side: saves a guaranteed revert +
      // wasted gas. The contract's InsufficientBalance() remains the backstop.
      const bal = await vault.balanceOf(account);
      if (value > bal) {
        setStatus(`You can withdraw at most ${usd(Number(formatUnits(bal, CONFIG.assetDecimals)), 2)}.`, "err");
        return;
      }
      setStatus("Confirm the withdrawal in your wallet…", "pending");
      const tx = await vault.withdraw(value);
      setStatus("Withdrawing… waiting for confirmation.", "pending");
      await tx.wait();
      setStatus("Withdrawal confirmed. Funds are back in your wallet.", "ok");
      toast("Withdrawal confirmed ✓", "ok");
    }
    refresh();
    loadPosition();
    loadWinners();
    setTimeout(closeModal, 1800);
  } catch (err) {
    console.warn("[CB] tx failed:", err);
    const reason = (err && (err.shortMessage || err.reason || err.message)) || "Transaction failed.";
    setStatus(reason.length > 120 ? reason.slice(0, 120) + "…" : reason, "err");
  } finally {
    txInFlight = false;
    $("modalAction").disabled = false;
  }
}

// ---- Past drawings (winners feed) ------------------------------------------
async function loadWinners() {
  const bodies = ["drawingsBody", "homeDrawingsBody"].map($).filter(Boolean);
  if (!bodies.length) return;
  try {
    const { formatUnits } = await eth();
    const { provider, vault } = await readVault();
    // The public Base RPC caps eth_getLogs at a 10,000-block range, so page through
    // [deployBlock … latest] in windows instead of one open-ended query (which 413s).
    const SPAN = 9_000;
    const latest = await provider.getBlockNumber();
    const filter = vault.filters.PrizeAwarded();
    const events = [];
    for (let from = CONFIG.deployBlock; from <= latest; from += SPAN + 1) {
      const to = Math.min(from + SPAN, latest);
      events.push(...await vault.queryFilter(filter, from, to));
    }
    if (!events.length) {
      bodies.forEach((b) => { b.innerHTML = `<p class="drawings-empty">No drawings yet — the first prize is awarded after the inaugural weekly draw.</p>`; });
      return;
    }
    // newest first
    events.reverse();
    // Fetch each distinct block once (dedupe), and never let a single null/missing block
    // (recent or reorged) reject the whole Promise.all and blank the entire table.
    const blockTimes = new Map();
    await Promise.all([...new Set(events.map((e) => e.blockNumber))].map(async (bn) => {
      try { const blk = await provider.getBlock(bn); if (blk) blockTimes.set(bn, Number(blk.timestamp)); }
      catch { /* leave unset → row falls back to a dash */ }
    }));
    const rows = events.map((ev) => {
      const ts = blockTimes.get(ev.blockNumber);
      const date = ts ? new Date(ts * 1000).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" }) : "—";
      const w = ev.args.winner, c = ev.args.charity;
      const wAmt = usd(Number(formatUnits(ev.args.winnerAmount, CONFIG.assetDecimals)), 2);
      const cAmt = usd(Number(formatUnits(ev.args.charityAmount, CONFIG.assetDecimals)), 2);
      // XSS invariant: ONLY ethers-normalized scalars (address/uint/bytes32) and the
      // hardcoded CONFIG.explorer may be interpolated here. Never interpolate a free-text
      // field (e.g. an on-chain string) into this innerHTML — it would be a stored-XSS
      // sink via a malicious RPC. Add such fields with createElement/textContent instead.
      return `<tr>
        <td>${date}</td>
        <td><a class="addr" href="${CONFIG.explorer}/address/${w}" target="_blank" rel="noopener">${shortAddr(w)}</a></td>
        <td class="amt">${wAmt}</td>
        <td><a class="addr" href="${CONFIG.explorer}/address/${c}" target="_blank" rel="noopener">${shortAddr(c)}</a></td>
        <td class="amt">${cAmt}</td>
        <td><a class="addr" href="${CONFIG.explorer}/tx/${ev.transactionHash}" target="_blank" rel="noopener">proof ↗</a></td>
      </tr>`;
    });
    const table = `<table class="drawings">
      <thead><tr><th>Date</th><th>Winner</th><th>Prize</th><th>Charity</th><th>Gift</th><th>Verify</th></tr></thead>
      <tbody>${rows.join("")}</tbody></table>`;
    bodies.forEach((b) => { b.innerHTML = table; });
  } catch (err) {
    console.warn("[CB] winners read failed:", err);
    bodies.forEach((b) => { b.innerHTML = `<p class="drawings-empty">Past drawings are on-chain — <a class="addr" href="${CONFIG.explorer}/address/${CONFIG.contractAddress}#events" target="_blank" rel="noopener">view the event log ↗</a></p>`; });
  }
}

// ---- Toasts -----------------------------------------------------------------
function toast(msg, type = "ok") {
  let host = $("toastHost");
  if (!host) { host = document.createElement("div"); host.id = "toastHost"; host.className = "toast-host"; document.body.appendChild(host); }
  const t = document.createElement("div");
  t.className = "toast " + type;
  t.textContent = msg;
  host.appendChild(t);
  setTimeout(() => { t.classList.add("out"); setTimeout(() => t.remove(), 400); }, 4200);
}

// ---- Sanctions / jurisdiction screen ----------------------------------------
// Matches PoolTogether: block comprehensively US-embargoed countries (OFAC); no
// US-state geofencing. Same-origin via Cloudflare's /cdn-cgi/trace, so no third
// party and no CSP change. Fails OPEN on error (a geo hiccup must not break the
// site for everyone) — the hard block is the Cloudflare WAF rule + the Terms.
let jurisdictionBlocked = false;
const REGION_MSG = "Charity Billionaire isn't available in your region.";

async function checkJurisdiction() {
  try {
    const res = await fetch("/cdn-cgi/trace", { cache: "no-store" });
    const loc = ((await res.text()).match(/^loc=([A-Z]{2})/m) || [])[1] || "";
    if (loc && CONFIG.blockedCountries.includes(loc)) {
      jurisdictionBlocked = true;
      showRegionBlock();
    }
  } catch (err) {
    console.warn("[CB] jurisdiction check skipped:", err);
  }
}

function showRegionBlock() {
  if ($("regionBlock")) return;
  const bar = document.createElement("div");
  bar.id = "regionBlock";
  bar.className = "region-block";
  bar.textContent =
    REGION_MSG + " Deposits are unavailable here. Existing deposits remain withdrawable directly from the non-custodial contract.";
  document.body.appendChild(bar);
  ["depositBtn", "connectBtn"].forEach((id) => { if ($(id)) $(id).disabled = true; });
}

// ---- Boot -------------------------------------------------------------------
function init() {
  checkJurisdiction();
  tickClock();
  setInterval(tickClock, 1000);
  // Paint the hero figures (prize/pool/charity) first; defer the heavier winners
  // block-scan until after, so it doesn't compete for the RPC on first load.
  refresh().finally(() => loadWinners());
  setInterval(refresh, 30_000);

  if ($("connectBtn")) $("connectBtn").addEventListener("click", connectWallet);
  if ($("depositBtn")) $("depositBtn").addEventListener("click", () => openModal("deposit"));
  if ($("withdrawBtn")) $("withdrawBtn").addEventListener("click", () => openModal("withdraw"));
  if ($("modalClose")) $("modalClose").addEventListener("click", closeModal);
  if ($("modalAction")) $("modalAction").addEventListener("click", submitModal);
  if ($("txModal")) $("txModal").addEventListener("click", (e) => { if (e.target.id === "txModal") closeModal(); });
  document.querySelectorAll("[data-open-deposit]").forEach((el) =>
    el.addEventListener("click", (e) => { e.preventDefault(); openModal("deposit"); }));
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
else init();
