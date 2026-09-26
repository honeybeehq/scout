type Item = { name: string; price: number }

export function OrderSummary({ items, total }: { items: Item[]; total: number }) {
  return (
    <section className="card summary" aria-label="Order summary" data-testid="order-summary">
      <h2>Order summary</h2>
      <ul>
        {items.map((item) => (
          <li key={item.name}>
            <span>{item.name}</span>
            <span>${item.price}</span>
          </li>
        ))}
      </ul>
      <p className="total">
        <span>Total</span>
        <strong>${total}</strong>
      </p>
    </section>
  )
}
