import { EmailField } from "./EmailField"
import { PayButton } from "./PayButton"

export function PaymentForm({ total }: { total: number }) {
  const applyPromo = () => {
    fetch("/api/promo?code=SPRING-SECRET", { method: "POST" }).catch(() => {})
  }

  const breakCheckout = () => {
    throw new Error("Checkout exploded: order total is undefined")
  }

  return (
    <form className="card payment" onSubmit={(event) => event.preventDefault()}>
      <h2>Payment</h2>
      <EmailField />
      <div className="actions">
        <PayButton amount={total} currency="USD" />
        <button type="button" className="secondary" onClick={applyPromo}>
          Apply promo
        </button>
        <button type="button" className="danger" onClick={breakCheckout}>
          Break checkout
        </button>
      </div>
    </form>
  )
}
