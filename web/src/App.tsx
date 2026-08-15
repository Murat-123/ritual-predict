import { useEffect, useMemo, useState } from "react";
import { createWalletClient, custom, formatUnits, getAddress, parseUnits, type Address } from "viem";

type Side = "yes" | "no";
type Asset = "BTC" | "ETH" | "SOL" | "BNB" | "XRP";
type InjectedProvider = { request: (args: { method: string; params?: unknown[] }) => Promise<unknown>; on?: (event: "accountsChanged", listener: (accounts: string[]) => void) => void; removeListener?: (event: "accountsChanged", listener: (accounts: string[]) => void) => void };
type MarketDefinition = { asset: Asset; question: string; target: number; initialOracleValue: number; initialYesPool: bigint; initialNoPool: bigint };
type Prediction = { side: Side; amount: bigint; createdAt: number };
type MarketState = { yesPool: bigint; noPool: bigint; selectedSide: Side; amount: string; oracleValue: number; resolved: boolean; history: Prediction[] };

declare global { interface Window { ethereum?: InjectedProvider } }

const token = (value: number) => BigInt(value) * 10n ** 18n;
const markets: MarketDefinition[] = [
  { asset: "BTC", question: "Will BTC/USD be at least", target: 120000, initialOracleValue: 123400, initialYesPool: token(145), initialNoPool: token(98) },
  { asset: "ETH", question: "Will ETH/USD be at least", target: 4000, initialOracleValue: 4286, initialYesPool: token(124), initialNoPool: token(80) },
  { asset: "SOL", question: "Will SOL/USD be at least", target: 250, initialOracleValue: 268, initialYesPool: token(81), initialNoPool: token(100) },
  { asset: "BNB", question: "Will BNB/USD be at least", target: 1000, initialOracleValue: 945, initialYesPool: token(116), initialNoPool: token(84) },
  { asset: "XRP", question: "Will XRP/USD be at least", target: 3.5, initialOracleValue: 3.72, initialYesPool: token(102), initialNoPool: token(100) },
];
const pipeline = [["Ritual Scheduler", "Scheduled callback wakes the market"], ["TEE Executor", "HTTP-capable executor selected"], ["HTTP Precompile", "Attested external data request"], ["jq", "Numeric oracle field extracted"], ["Oracle Value", "Observed price returned on-chain"], ["Automatic Resolution", "Contract compares and settles"]] as const;
const SESSION_ACCOUNT_KEY = "ritual-predict-account";
const createMarketState = (market: MarketDefinition): MarketState => ({ yesPool: market.initialYesPool, noPool: market.initialNoPool, selectedSide: "yes", amount: "1.00", oracleValue: market.initialOracleValue, resolved: false, history: [] });
const createInitialStates = () => Object.fromEntries(markets.map((market) => [market.asset, createMarketState(market)])) as Record<Asset, MarketState>;
const ritual = (value: bigint) => Number(formatUnits(value, 18)).toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 2 });
const usd = (value: number) => `$${value.toLocaleString("en-US", { minimumFractionDigits: value % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
const shortAddress = (address: Address) => `${address.slice(0, 6)}…${address.slice(-4)}`;

export function App() {
  const [activeAsset, setActiveAsset] = useState<Asset>("ETH");
  const [marketStates, setMarketStates] = useState<Record<Asset, MarketState>>(createInitialStates);
  const [account, setAccount] = useState<Address | null>(null);
  const [notice, setNotice] = useState("Choose a position to simulate a prediction.");
  const [step, setStep] = useState(-1);
  const [resolving, setResolving] = useState(false);
  const [blocks, setBlocks] = useState(42);
  const market = useMemo(() => markets.find((item) => item.asset === activeAsset)!, [activeAsset]);
  const state = marketStates[activeAsset];
  const total = state.yesPool + state.noPool;
  const yesPct = Number((state.yesPool * 10000n) / total) / 100;
  const outcome = state.oracleValue >= market.target ? "YES" : "NO";

  useEffect(() => {
    if (state.resolved) return undefined;
    const timer = window.setInterval(() => setBlocks((value) => value > 0 ? value - 1 : 42), 1700);
    return () => window.clearInterval(timer);
  }, [state.resolved]);

  useEffect(() => {
    const provider = window.ethereum;
    if (!provider) return undefined;
    const restore = async () => {
      const saved = window.sessionStorage.getItem(SESSION_ACCOUNT_KEY);
      if (!saved) return;
      try { const accounts = await provider.request({ method: "eth_accounts" }) as string[]; const restored = accounts.find((item) => item.toLowerCase() === saved.toLowerCase()); if (restored) setAccount(getAddress(restored)); else window.sessionStorage.removeItem(SESSION_ACCOUNT_KEY); } catch { window.sessionStorage.removeItem(SESSION_ACCOUNT_KEY); }
    };
    const changed = (accounts: string[]) => { if (accounts[0]) { const next = getAddress(accounts[0]); setAccount(next); window.sessionStorage.setItem(SESSION_ACCOUNT_KEY, next); } else { setAccount(null); window.sessionStorage.removeItem(SESSION_ACCOUNT_KEY); } };
    void restore(); provider.on?.("accountsChanged", changed); return () => provider.removeListener?.("accountsChanged", changed);
  }, []);

  async function connectWallet() {
    const provider = window.ethereum;
    if (!provider) return setNotice("No browser wallet found. Install or unlock MetaMask, then try again.");
    try { const wallet = createWalletClient({ transport: custom(provider) }); const accounts = await provider.request({ method: "eth_requestAccounts" }) as string[]; const selected = accounts[0] ?? (await wallet.getAddresses())[0]; if (!selected) return setNotice("MetaMask did not return an account. Unlock it and try again."); const next = getAddress(selected); setAccount(next); window.sessionStorage.setItem(SESSION_ACCOUNT_KEY, next); setNotice(`${shortAddress(next)} connected.`); } catch { setNotice("Wallet connection was cancelled or unavailable. No transaction was sent."); }
  }
  function disconnectWallet() { setAccount(null); window.sessionStorage.removeItem(SESSION_ACCOUNT_KEY); setNotice("Wallet disconnected from this browser session."); }
  function updateCurrentMarket(update: (current: MarketState) => MarketState) { setMarketStates((current) => ({ ...current, [activeAsset]: update(current[activeAsset]) })); }
  function selectMarket(asset: Asset) { if (resolving) return; setActiveAsset(asset); setStep(-1); setBlocks(42); setNotice(`${asset} market selected.`); }
  function placePrediction() {
    if (state.resolved) return setNotice("This market has already resolved. Reset it to place another prediction.");
    try { const value = parseUnits(state.amount || "0", 18); if (value <= 0n) return setNotice("Enter an amount greater than zero."); updateCurrentMarket((current) => ({ ...current, yesPool: current.selectedSide === "yes" ? current.yesPool + value : current.yesPool, noPool: current.selectedSide === "no" ? current.noPool + value : current.noPool, history: [...current.history, { side: current.selectedSide, amount: value, createdAt: Date.now() }] })); setNotice("Simulation only — no on-chain transaction."); } catch { setNotice("Use a valid numeric amount, for example 1.25."); }
  }
  async function runResolution() {
    if (resolving || state.resolved) return;
    const asset = activeAsset; const currentMarket = market; const value = state.oracleValue;
    setResolving(true); setNotice(`Resolving ${asset} through the Ritual pipeline…`);
    for (let index = 0; index < pipeline.length; index += 1) { setStep(index); await new Promise((done) => window.setTimeout(done, 720)); }
    const result = value >= currentMarket.target ? "YES" : "NO";
    setMarketStates((current) => ({ ...current, [asset]: { ...current[asset], resolved: true } })); setBlocks(0); setNotice(`${asset} resolved ${result}: ${usd(value)} compared with ${usd(currentMarket.target)}.`); setResolving(false);
  }
  function resetMarket() { setMarketStates((current) => ({ ...current, [activeAsset]: createMarketState(market) })); setStep(-1); setBlocks(42); setResolving(false); setNotice(`${activeAsset} market reset and open for predictions.`); }

  return <main className="site-shell" id="top">
    <div className="background-image" /><div className="aurora a1" /><div className="aurora a2" />
    <nav className="nav wrap"><a className="brand" href="#top"><b>R</b> RITUAL PREDICT</a><div className="nav-right"><span className="mode"><i />Local Mode</span>{account ? <><button className="wallet connected-wallet" onClick={disconnectWallet} title="Disconnect wallet">{shortAddress(account)}</button><button className="disconnect" onClick={disconnectWallet}>Disconnect</button></> : <button className="wallet" onClick={connectWallet}>Connect Wallet</button>}</div></nav>
    <section className="hero wrap"><div><p className="eyebrow">AUTONOMOUS MARKET INFRASTRUCTURE</p><h1>RITUAL <em>PREDICT</em></h1><p className="subtitle">Autonomous Prediction Markets</p><p className="intro">A self-resolving binary market powered by the Ritual Scheduler, attested HTTP, and deterministic on-chain extraction.</p><p className="offline"><i />Ritual public testnet is currently offline — running in local simulation mode.</p></div><aside className="glass hero-state"><span>MARKET STATUS</span><strong className={state.resolved ? "done" : "open"}>{state.resolved ? `RESOLVED · ${outcome}` : "OPEN · LOCAL"}</strong><hr /><small>{state.resolved ? "Automatic resolution complete" : `${blocks} blocks until resolution`}</small></aside></section>
    <section className="wrap market-grid"><article className="glass market"><div className="topline"><span>FEATURED MARKET · #{activeAsset}-01</span><b>TARGET {usd(market.target)}</b></div><div className="market-selector" aria-label="Select a market">{markets.map((item) => <button className={item.asset === activeAsset ? "selected" : ""} disabled={resolving} key={item.asset} onClick={() => selectMarket(item.asset)}><i /><span>{item.asset}</span></button>)}</div><h2>{market.question} <em>{usd(market.target)}</em> at resolution?</h2><div className="metrics"><div><span>SIMULATED ORACLE</span><strong className="price">{usd(state.oracleValue)}</strong></div><div><span>RESOLUTION</span><strong>{state.resolved ? "Complete" : `${blocks} blocks`}</strong></div><div><span>STATE</span><strong>{state.resolved ? `Resolved ${outcome}` : "Open"}</strong></div></div><div className="outcomes"><Outcome side="YES" percent={yesPct} pool={state.yesPool} yes /><Outcome side="NO" percent={100 - yesPct} pool={state.noPool} /></div><div className="total"><span>TOTAL POOL</span><strong>{ritual(total)} <small>RITUAL</small></strong></div></article>
    <aside className="glass prediction"><div><span>PLACE A PREDICTION</span><h3>{state.resolved ? `Resolved · ${outcome}` : "Choose your outcome"}</h3></div><div className="choices"><button className={state.selectedSide === "yes" ? "selected yes" : "yes"} disabled={state.resolved} onClick={() => updateCurrentMarket((current) => ({ ...current, selectedSide: "yes" }))}>YES</button><button className={state.selectedSide === "no" ? "selected no" : "no"} disabled={state.resolved} onClick={() => updateCurrentMarket((current) => ({ ...current, selectedSide: "no" }))}>NO</button></div><label>AMOUNT <div><input value={state.amount} disabled={state.resolved} onChange={(event) => updateCurrentMarket((current) => ({ ...current, amount: event.target.value }))} inputMode="decimal" aria-label="Prediction amount" /><b>RITUAL</b></div></label><button className="primary" onClick={placePrediction} disabled={state.resolved}>Place Prediction <b>↗</b></button>{state.resolved && <button className="reset" onClick={resetMarket}>Reset Market</button>}<p className="note">Simulation only — no on-chain transaction.</p><p className="prediction-history">{state.history.length} prediction{state.history.length === 1 ? "" : "s"} this session</p><p className="notice" aria-live="polite">{notice}</p></aside></section>
    <section className="pipeline-section wrap"><div className="heading"><div><p className="eyebrow">RITUAL RESOLUTION PIPELINE · {activeAsset}</p><h2>A market that resolves itself.</h2></div><button className="run" onClick={runResolution} disabled={resolving || state.resolved}>{resolving ? "Resolving…" : state.resolved ? "Resolved" : "Run Resolution"}</button></div><div className="pipeline">{pipeline.map(([title, caption], index) => <div className="pipe-item" key={title}><div className={`node ${state.resolved || index < step ? "done" : index === step ? "active" : ""}`}>{String(index + 1).padStart(2, "0")}</div><h3>{title}</h3><p>{caption}</p>{index < pipeline.length - 1 && <i className={state.resolved || index < step ? "line done" : index === step ? "line active" : "line"} />}</div>)}</div></section>
    <section className="wrap technical"><article className="glass tech-copy"><p className="eyebrow">HOW IT WORKS</p><h2>Production architecture.<br /><em>Interactive implementation.</em></h2><p>The production contract is a self-resolving binary prediction market. Ritual Scheduler invokes the callback, the TEE Registry selects an HTTP-capable executor, HTTP retrieves external data, and jq extracts the numeric value used for settlement.</p></article><ul className="glass facts"><li><b>01</b>Failed oracle reads retry up to three times; failures are never interpreted as NO.</li><li><b>02</b>Unresolvable and empty-winning-side markets refund every participant.</li><li><b>03</b>Winnings are proportional, pari-mutuel, and claimed pull-style.</li><li><b>04</b><strong>18 / 18</strong> local Solidity tests passing. This site does not claim a live deployment.</li></ul></section>
    <footer className="wrap footer"><span>Built for Ritual</span><div><a href="https://x.com/ritualnet" target="_blank" rel="noreferrer">X / Ritual</a><a href="https://discord.gg/ritual-net" target="_blank" rel="noreferrer">Discord</a><a href="https://docs.ritualfoundation.org" target="_blank" rel="noreferrer">Docs</a></div></footer>
  </main>;
}

function Outcome({ side, percent, pool, yes = false }: { side: string; percent: number; pool: bigint; yes?: boolean }) { return <div className={`outcome ${yes ? "yes" : "no"}`}><div><b>{side}</b><strong>{percent.toFixed(1)}%</strong></div><span><i style={{ width: `${percent}%` }} /></span><p>{ritual(pool)} RITUAL</p></div>; }
