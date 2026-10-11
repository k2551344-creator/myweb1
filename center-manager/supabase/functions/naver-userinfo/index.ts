// Normalize Naver's nested response for Supabase Custom OAuth2 userinfo.
Deno.serve(async(req:Request)=>{
 if(req.method!=='GET')return new Response('Method not allowed',{status:405});
 const token=req.headers.get('authorization');if(!token?.startsWith('Bearer '))return new Response('Unauthorized',{status:401});
 try{
  const response=await fetch('https://openapi.naver.com/v1/nid/me',{headers:{Authorization:token},signal:AbortSignal.timeout(10000)});
  const data=await response.json();if(!response.ok||data.resultcode!=='00'||!data.response?.id)return new Response('Unauthorized',{status:401});
  const profile=data.response;
  // Email optional: do not assert email verification or auto-link by unverified email.
  return Response.json({sub:profile.id,id:profile.id,name:profile.name??profile.nickname??'회원',preferred_username:profile.name??profile.nickname??'회원'},{headers:{'Cache-Control':'no-store'}});
 }catch{return new Response('Provider unavailable',{status:502});}
});
