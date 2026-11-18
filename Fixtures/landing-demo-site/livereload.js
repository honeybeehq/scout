(() => {
  const files = ["index.html", "styles.css"]
  let last = null
  const read = () => Promise.all(files.map((file) => fetch(file, { cache: "no-store" }).then((r) => r.text()))).then((texts) => texts.join("\u0000"))
  const tick = () => {
    read()
      .then((text) => {
        if (last !== null && text !== last) location.reload()
        last = text
      })
      .catch(() => {})
      .finally(() => setTimeout(tick, 400))
  }
  tick()
})()
