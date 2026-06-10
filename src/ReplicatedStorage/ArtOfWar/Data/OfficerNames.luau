local OfficerNames = {}

OfficerNames.pools = {
	french = {
		first = { "Jean", "Pierre", "Louis", "Henri", "Charles", "Antoine", "Francois", "Philippe", "Gaspard", "Andre" },
		last = { "de Broglie", "de Saxe", "de Villars", "de Choiseul", "de Soubise", "de Conde", "de Turenne", "Berthier", "Lafayette", "Massena" },
	},
	english = {
		first = { "John", "William", "Edward", "George", "Richard", "Henry", "James", "Thomas", "Arthur", "Charles" },
		last = { "Wellesley", "Marlborough", "Cumberland", "Cornwallis", "Carteret", "Granby", "Hawley", "Amherst", "Ligonier", "Conway" },
	},
	castilian = {
		first = { "Diego", "Pedro", "Juan", "Carlos", "Fernando", "Alonso", "Gonzalo", "Rodrigo", "Miguel", "Alvaro" },
		last = { "de Toledo", "de Cordoba", "Pizarro", "de Leiva", "de Borbon", "Spinola", "de la Cueva", "de Velasco", "de Alba", "de Aranda" },
	},
	russian = {
		first = { "Aleksandr", "Pyotr", "Mikhail", "Ivan", "Nikolai", "Sergei", "Pavel", "Grigori", "Boris", "Fyodor" },
		last = { "Suvorov", "Rumyantsev", "Saltykov", "Apraksin", "Sheremetev", "Repnin", "Potemkin", "Bagration", "Kutuzov", "Golitsyn" },
	},
	prussian = {
		first = { "Friedrich", "Wilhelm", "Karl", "Heinrich", "Ferdinand", "Hans", "Ludwig", "Otto", "Albrecht", "Ernst" },
		last = { "von Seydlitz", "von Zieten", "von Schwerin", "von Keith", "von Anhalt", "von Bevern", "von Winterfeldt", "von Bredow", "von der Marwitz", "von Rohr" },
	},
	austrian = {
		first = { "Karl", "Leopold", "Joseph", "Franz", "Anton", "Maximilian", "Johann", "Eugen", "Wenzel", "Andreas" },
		last = { "von Daun", "von Loudon", "Lacy", "Lichtenstein", "Hadik", "Khevenhuller", "Browne", "von Soro", "von Kheul", "Wallis" },
	},
	turkish = {
		first = { "Ahmet", "Mehmet", "Mustafa", "Suleyman", "Ibrahim", "Halil", "Osman", "Yusuf", "Bayram", "Murat" },
		last = { "Pasha", "Bey", "Aga", "Koprulu", "Kara", "Ozdemir", "Tiryaki", "Ragip", "Hekimoglu", "Yegen" },
	},
	korean = {
		first = { "Yi", "Kim", "Park", "Choi", "Jung", "Han", "Kang", "Cho", "Yoon", "Oh" },
		last = { "Sun-shin", "Eok-gi", "Jong-mu", "Ban", "Won-gyun", "Ung-ryeong", "Hyun-chung", "Jin", "Hyo", "Jeong" },
	},
	manchu = {
		first = { "Aisin", "Fucha", "Niohuru", "Tunggiya", "Magiya", "Gioro", "Yehe", "Tatara", "Hesheri", "Sirin" },
		last = { "Gioro", "Tunggiya", "Niohuru", "Borjigit", "Khorchin", "Tatara", "Yehenara", "Gualgiya", "Suwan", "Wanggiya" },
	},
	japanese = {
		first = { "Hideyoshi", "Ieyasu", "Takeda", "Date", "Mori", "Honda", "Sakai", "Toyotomi", "Tokugawa", "Maeda" },
		last = { "Kenshin", "Shingen", "Masamune", "Motonari", "Tadakatsu", "Tadakiyo", "Hideyoshi", "Ieyasu", "Toshiie", "Yoshihiro" },
	},
	dutch = {
		first = { "Willem", "Maurits", "Johan", "Cornelis", "Pieter", "Hendrik", "Jacob", "Adriaan", "Frederik", "Karel" },
		last = { "van Wassenaer", "van Nassau", "van Brederode", "van Aylva", "van Reede", "van Ginkel", "Cronstrom", "van Schuylenburch", "van Hardenbroek", "van Tuyll" },
	},
	danish = {
		first = { "Christian", "Frederik", "Niels", "Peder", "Jens", "Hans", "Anders", "Ulrik", "Valdemar", "Knud" },
		last = { "Juel", "Gyldenlove", "Rantzau", "Reventlow", "Schack", "Ahlefeldt", "Wedel", "Trolle", "Rosenkrantz", "Brockenhuus" },
	},
	swedish = {
		first = { "Carl", "Gustaf", "Erik", "Axel", "Magnus", "Fredrik", "Adolf", "Nils", "Johan", "Hans" },
		last = { "Lewenhaupt", "Stenbock", "Rehnskiold", "Armfeldt", "Cronstedt", "Posse", "Sparre", "Horn", "Ehrensvard", "Hamilton" },
	},
	polish = {
		first = { "Stanislaw", "Jan", "Kazimierz", "Michal", "Jozef", "Franciszek", "Adam", "Karol", "Ignacy", "Antoni" },
		last = { "Poniatowski", "Czartoryski", "Branicki", "Potocki", "Lubomirski", "Rzewuski", "Sapieha", "Oginski", "Zamoyski", "Radziwill" },
	},
	portuguese = {
		first = { "Joao", "Pedro", "Manuel", "Afonso", "Sebastiao", "Luis", "Antonio", "Francisco", "Diogo", "Henrique" },
		last = { "de Mello", "de Braganca", "da Cunha", "de Lima", "de Castro", "de Almeida", "de Tavora", "de Noronha", "da Costa", "Pereira" },
	},
	bavarian = {
		first = { "Maximilian", "Ferdinand", "Klemens", "Joseph", "Albrecht", "Theodor", "Kajetan", "Ludwig", "Sigmund", "Anton" },
		last = { "von Seinsheim", "von Torring", "von Preysing", "von Wahl", "von Minucci", "von Holnstein", "von Berchem", "von Horwarth", "von Gronsfeld", "von Daun" },
	},
	saxon = {
		first = { "Friedrich", "August", "Johann", "Moritz", "Christian", "Heinrich", "Anton", "Xaver", "Albrecht", "Kasimir" },
		last = { "Rutowski", "von Arnim", "von Bruhl", "von Flemming", "von Wackerbarth", "von Schonberg", "von Bose", "von Gersdorff", "von Pflugk", "von Sachsen" },
	},
	hannoverian = {
		first = { "Georg", "Ernst", "Ludwig", "August", "Friedrich", "Wilhelm", "Christian", "Johann", "Karl", "Heinrich" },
		last = { "von dem Bussche", "von Sporcken", "von Hardenberg", "von Zastrow", "von Estorff", "von Reden", "von Wangenheim", "von Munchhausen", "von Diepenbroick", "von Linsingen" },
	},
	catalan = {
		first = { "Jordi", "Pere", "Joan", "Antoni", "Francesc", "Miquel", "Ramon", "Josep", "Carles", "Bernat" },
		last = { "de Montcada", "Despujol", "de Cardona", "Sagarra", "de Peguera", "Folch", "de Cruilles", "Vilanova", "de Rocaberti", "Safont" },
	},
	sicilian = {
		first = { "Carlo", "Ruggero", "Federico", "Antonio", "Giuseppe", "Vincenzo", "Francesco", "Salvatore", "Domenico", "Gaetano" },
		last = { "di Sangro", "Caracciolo", "Pignatelli", "Filangieri", "Branciforte", "Ventimiglia", "Moncada", "Tagliavia", "Alliata", "Lanza" },
	},
	tatar = {
		first = { "Selim", "Devlet", "Kaplan", "Arslan", "Mengli", "Sahib", "Murad", "Gazi", "Kirim", "Bahadir" },
		last = { "Giray", "Shirin", "Mansur", "Barin", "Argin", "Yashlav", "Sicivut", "Kipchak", "Nogai", "Or-Bey" },
	},
	akan = {
		first = { "Kofi", "Kwame", "Kwaku", "Yaw", "Kwabena", "Kojo", "Kwasi", "Osei", "Opoku", "Akwasi" },
		last = { "Tutu", "Bonsu", "Frempong", "Boateng", "Agyeman", "Asante", "Kusi", "Owusu", "Sarpong", "Badu" },
	},
	iroquoian = {
		first = { "Joseph", "Hendrick", "Cornplanter", "Sayenqueraghta", "Skenandoa", "Canassatego", "Kiasutha", "Logan", "Theyanoguin", "Hiokatoo" },
		last = { "Brant", "Thayendanegea", "Guyasuta", "Old Smoke", "Half-King", "Karonghyontye", "Honayawas", "Tahgahjute", "Shononses", "Tekarihoken" },
	},
	generic = {
		first = { "Marcus", "Anton", "Henri", "Lucas", "Carl", "Otto", "Alexei", "Stefan", "Gilles", "Hector" },
		last = { "the Bold", "the Wise", "the Stern", "Cromwell", "Vaughn", "Roland", "Conway", "Brooke", "Marcellus", "Reinhardt" },
	},
}

local function pick(list, rng)
	if not list or #list == 0 then return nil end
	return list[rng:NextInteger(1, #list)]
end

function OfficerNames.roll(culture, seed)
	local rng = seed and Random.new(seed) or Random.new()
	local pool = OfficerNames.pools[culture] or OfficerNames.pools.generic
	local first = pick(pool.first, rng)
	local last = pick(pool.last, rng)
	if not first then return "Commander" end
	if not last then return first end
	return first .. " " .. last
end

function OfficerNames.cultureKeys()
	local out = {}
	for k in pairs(OfficerNames.pools) do table.insert(out, k) end
	return out
end

return OfficerNames
