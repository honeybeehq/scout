export function PayButton({ amount, currency }: { amount: number; currency: string }) {
  return (
    <button type="submit" className="pay" data-testid="pay-now" title={`${currency} ${amount}`}>
      Pay now
    </button>
  )
}
