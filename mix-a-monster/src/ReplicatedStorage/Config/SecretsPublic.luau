--!strict
--[[
	SecretsPublic.luau — everything the client is allowed to know about
	secrets before it discovers one (GDD §7.4, §11.3).

	This is COUNT and nothing else. The Mixdex renders COUNT "???" silhouettes
	and fills one in when the server tells it a secret was produced. There is
	deliberately no name, no ingredient, and no hint here: a client that dumps
	ReplicatedStorage learns only how many are left to find.

	Keep COUNT in step with ServerStorage/SecretRecipes.luau. SecretsService
	asserts they match at boot, so a mismatch fails loudly in Studio rather
	than quietly shipping a wrong Mixdex denominator.
]]

return {
	COUNT = 5,
}
