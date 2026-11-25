export default function Home() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-3xl flex-col justify-center gap-4 px-6">
      <h1 className="text-3xl font-semibold">Chaser</h1>
      <p>Keeps a Uniswap v4 liquidity position near the price after a trend leaves it behind, without swaps.</p>
    </main>
  );
}
