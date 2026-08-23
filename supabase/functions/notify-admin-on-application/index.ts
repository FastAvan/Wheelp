import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const ADMIN_EMAIL = "aelguer@icloud.com"

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  )

  const { data } = await supabase.auth.admin.listUsers()
  const admin = data?.users.find(u => u.email === ADMIN_EMAIL)
  if (!admin) return new Response("Admin no encontrado", { status: 200 })

  const { data: row } = await supabase
    .from("push_tokens")
    .select("token")
    .eq("user_id", admin.id)
    .single()
  if (!row?.token) return new Response("Sin token APNs del admin", { status: 200 })

  const sendPushUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/send-push`
  await fetch(sendPushUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}`,
    },
    body: JSON.stringify({
      token: row.token,
      title: "Wheelp: nueva solicitud",
      body: "Hay una nueva solicitud de ayudante pendiente de revisión.",
    }),
  })

  return new Response("OK", { status: 200 })
})
