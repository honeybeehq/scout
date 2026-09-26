import { useEffect } from "react"
import { CheckoutPage } from "./checkout/CheckoutPage"
import { OrdersPage } from "./orders/OrdersPage"
import { navigate, usePath } from "./router"

export function App() {
  const path = usePath()
  const onOrders = path.startsWith("/orders")

  useEffect(() => {
    document.title = onOrders ? "Orders · Acme" : "Checkout · Acme"
  }, [onOrders])

  return (
    <div className="shell">
      <nav className="nav" aria-label="Main">
        <strong>Acme</strong>
        <button type="button" className="link" onClick={() => navigate("/checkout")}>
          Checkout
        </button>
        <button type="button" className="link" onClick={() => navigate("/orders?ref=nav#recent")}>
          Orders
        </button>
      </nav>
      {onOrders ? <OrdersPage /> : <CheckoutPage />}
    </div>
  )
}
