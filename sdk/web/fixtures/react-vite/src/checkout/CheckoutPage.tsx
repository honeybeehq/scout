import { OrderSummary } from "./OrderSummary"
import { PaymentForm } from "./PaymentForm"

const items = [
  { name: "Trail runners", price: 129 },
  { name: "Wool socks", price: 18 },
]

export function CheckoutPage() {
  const total = items.reduce((sum, item) => sum + item.price, 0)
  return (
    <main className="checkout">
      <h1>Checkout</h1>
      <div className="columns">
        <PaymentForm total={total} />
        <OrderSummary items={items} total={total} />
      </div>
    </main>
  )
}
