export interface SourceLocation {
  file: string
  line: number | null
  column: number | null
}

export interface Bounds {
  x: number
  y: number
  width: number
  height: number
  space: "viewport"
}

export interface Viewport {
  x: number
  y: number
  scale: number
}

export type SafeProps = Record<string, string | number | boolean | null>

export interface ElementDescriptor {
  id: string
  kind?: "game"
  game?: GameDescription
  role: string | null
  label: string | null
  text: string | null
  testId: string | null
  selector: string
  component: string | null
  ownerStack: string[]
  source: SourceLocation | null
  bounds: Bounds
  state: { disabled: boolean; focused: boolean }
  props: SafeProps | null
}

export interface RawSource {
  url: string
  line: number
  column: number | null
  generated: boolean
}

export interface ComponentInfo {
  component: string | null
  ownerStack: string[]
  source: RawSource | null
  props?: unknown
}

export interface FrameworkResolver {
  name: string
  detect(): { version: string | null } | null
  resolve(element: Element): ComponentInfo | null
}

export type PropsMode = "off" | "safe"

export interface ScoutConfig {
  port?: number
  token?: string
  projectRoot?: string
  serverRoot?: string
  gitBranch?: string
  app?: { name?: string }
  framework?: { name?: string; version?: string | null; meta?: string | null }
  props?: PropsMode
  route?: () => string | null | undefined
  signals?: boolean
}

export interface ScoutHandle {
  readonly connected: boolean
  readonly active: boolean
  game(config: GameConfig): () => void
  stop(): void
}

export interface PathRoots {
  projectRoot?: string | undefined
  serverRoot?: string | undefined
}

export interface GameDescription {
  entity: { id: string; kind: string; label: string }
  layer?: string
  scene?: string
  extra?: unknown
}

export interface GameSnapshot {
  scene: string
  seed?: string | number
  frame: number
  clock: number
  position: unknown
  save?: unknown
  extra?: unknown
}

export interface GameConfig {
  canvas: HTMLCanvasElement
  name: string
  build: string
  describe(point: { x: number; y: number }): GameDescription | null
  snapshot(): GameSnapshot | Promise<GameSnapshot>
}
