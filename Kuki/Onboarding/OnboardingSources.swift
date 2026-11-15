import Foundation

/// One study or guideline behind a claim on screen.
struct ScienceSource: Identifiable, Hashable {
    let id: String
    let short: String
    let url: URL
    var note: String? = nil
}

/// Every source the introduction cites. Each URL was checked to resolve to
/// the right paper or page (2026-11).
enum OnboardingSources {
    private static func link(_ s: String) -> URL { URL(string: s)! }

    static let noaa = ScienceSource(
        id: "noaa", short: "NOAA Global Monitoring Laboratory · Trends in atmospheric CO₂",
        url: link("https://gml.noaa.gov/ccgg/trends/"),
        note: String(localized: "Mauna Loa's monthly mean passed 430 ppm in May 2025. City air outdoors often reads a little higher.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let rudnick = ScienceSource(
        id: "rudnick2003", short: "Rudnick & Milton 2003 · Indoor Air",
        url: link("https://doi.org/10.1034/j.1600-0668.2003.00189.x"),
        note: String(localized: "The share of each breath already breathed out by someone is (indoor CO₂ − outdoor) ÷ the CO₂ breathing adds, about 38,000 ppm. The method is used to estimate how much exhaled air people share in a room, for example in airborne-infection research. Kūki doesn't measure germs.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let uba2008 = ScienceSource(
        id: "uba2008", short: "Umweltbundesamt 2008 · Bundesgesundheitsblatt",
        url: link("https://doi.org/10.1007/s00103-008-0707-2"),
        note: String(localized: "Below 1000 ppm \"hygienisch unbedenklich\", 1000–2000 \"auffällig\", above 2000 \"inakzeptabel\".", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay. The three German terms quote the source and stay in German."))
    static let ashrae = ScienceSource(
        id: "ashrae", short: "ASHRAE · Position Document on Indoor Carbon Dioxide",
        url: link("https://www.ashrae.org/about/position-documents"),
        note: String(localized: "CO₂ is used as an indicator of ventilation; ASHRAE's standards set no CO₂ limit based on health.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let cognition = ScienceSource(
        id: "cognition", short: "Satish et al. 2012 · Environmental Health Perspectives",
        url: link("https://doi.org/10.1289/ehp.1104789"),
        note: String(localized: "22 people, pure CO₂ at 600, 1000 and 2500 ppm: lower decision-making scores at 1000 and above. The authors asked for replication.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let allen = ScienceSource(
        id: "allen2016", short: "Allen et al. 2016 · Environmental Health Perspectives",
        url: link("https://doi.org/10.1289/ehp.1510037"),
        note: String(localized: "24 office workers at about 550, 945 and 1400 ppm: cognitive scores fell as ventilation fell.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let zhang = ScienceSource(
        id: "zhang2017", short: "Zhang et al. 2017 · Indoor Air",
        url: link("https://doi.org/10.1111/ina.12284"),
        note: String(localized: "25 people, pure CO₂ added to 1000 and 3000 ppm: no significant effect on thinking.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let du = ScienceSource(
        id: "du2020", short: "Du et al. 2020 · Indoor Air (a review)",
        url: link("https://doi.org/10.1111/ina.12706"),
        note: String(localized: "37 studies; the findings are inconsistent.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))

    static let stromTejsen = ScienceSource(
        id: "stromtejsen2016", short: "Strøm-Tejsen et al. 2016 · Indoor Air",
        url: link("https://doi.org/10.1111/ina.12254"),
        note: String(localized: "Small studies in single-occupancy student rooms: an open window (2585 → 660 ppm) and, separately, a quiet fan.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let kang = ScienceSource(
        id: "kang2024", short: "Kang et al. 2024 · Building and Environment",
        url: link("https://doi.org/10.1016/j.buildenv.2023.111118"),
        note: String(localized: "36 young adults in simulated bedrooms at 750, 1000 and 1300 ppm: sleep efficiency fell by 1.3 and 1.8 points.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let beko = ScienceSource(
        id: "beko2010", short: "Bekö et al. 2010 · Building and Environment",
        url: link("https://doi.org/10.1016/j.buildenv.2010.04.014"),
        note: String(localized: "500 Danish children's bedrooms: 23% passed 2000 ppm for 20 minutes or more; air changed about 0.46 times an hour.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let persily = ScienceSource(
        id: "persily2017", short: "Persily & de Jonge 2017 · Indoor Air",
        url: link("https://doi.org/10.1111/ina.12383"),
        note: String(localized: "CO₂ from a sleeping adult, used in Kūki's estimate: 0.0035 L/s, in a 30 m³ room with 0.5 air changes an hour.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))

    static let en16798 = ScienceSource(
        id: "en16798", short: "EN 16798-1:2019 · via REHVA Journal",
        url: link("https://rehva.eu/rehva-journal/chapter/new-health-comfort-promoting-cen-standard"),
        note: String(localized: "Bedrooms: about 380 ppm above outdoor air in the best category, 550 in the normal one — about 810 and 980 ppm.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let fan2023 = ScienceSource(
        id: "fan2023", short: "Fan et al. 2023 · Science of the Total Environment",
        url: link("https://doi.org/10.1016/j.scitotenv.2023.163805"),
        note: String(localized: "A field study in bedrooms; it suggests that keeping them below about 800 ppm may help sleep.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let rehva = ScienceSource(
        id: "rehva", short: "REHVA COVID-19 guidance, 2021",
        url: link("https://www.rehva.eu/fileadmin/user_upload/REHVA_COVID-19_guidance_document_V4.1_15042021.pdf"),
        note: String(localized: "Pandemic guidance: a yellow light at 800 ppm and red at 1000.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))

    static let ubaAiring = ScienceSource(
        id: "ubaAiring", short: "Umweltbundesamt · Wie lüfte ich richtig?",
        url: link("https://www.umweltbundesamt.de/themen/gesundheit/umwelteinfluesse-auf-den-menschen/schimmel/wie-luefte-ich-richtig-tipps-tricks-zu"),
        note: String(localized: "Windows wide for a few minutes, two or three times a day, and the bedroom after getting up; a tilted window airs poorly and costs heat. Opposite windows together air fastest.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))
    static let ubaSchools = ScienceSource(
        id: "ubaSchools", short: "Umweltbundesamt · Richtig lüften in Schulen",
        url: link("https://www.umweltbundesamt.de/richtig-lueften-in-schulen"),
        note: String(localized: "About 3–5 minutes wide open in cold weather, 10–20 on warm days.", comment: "Onboarding, Sources list: what a cited study or guideline says, shown under its citation. Numbers, units and proper names stay."))

    /// Screen 3 (Breath, with the dial).
    static let breath = [noaa, rudnick, uba2008, ashrae, cognition, allen, zhang, du]
    /// Screen 4 (Night).
    static let night = [stromTejsen, kang, beko, persily]
    /// The fūrin's limit rows.
    static let limits = [en16798, uba2008, fan2023, rehva]
    /// The plan's airing line.
    static let airing = [ubaAiring, ubaSchools]
}
