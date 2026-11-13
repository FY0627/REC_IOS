import Foundation
import BKModel

/// 刚开始记账时的小词库（ADR 0026）：交易对方里有这些词，猜它大概是哪个分类，排在推荐的第一个。
/// 只用来排序，不自动归类；这个商户用户自己选过以后，按用户选的。猜的分类只用默认分类里的（被删掉的就不猜）。
/// 吃饭的店按时段猜是哪一餐（`MealSlot`），不是饭点时猜「饮食」大类
enum CategoryLexicon {
    enum Target: Equatable {
        case category(String)
        /// 吃饭：按时段是早餐、午餐还是晚餐
        case meal
    }

    /// 从前往后找，先对上的算。具体的在前（「便利店」在「便利」前、「美团打车」这类出行在吃饭前）
    static let entries: [(words: [String], target: Target)] = [
        (["地铁", "公交", "轨道交通", "交通卡", "一卡通", "八达通", "metro", "mtr", "subway"], .category("ex.traffic.transit")),
        (["滴滴", "打车", "出租车", "网约车", "快车", "出行", "曹操", "uber", "taxi"], .category("ex.traffic.taxi")),
        (["加油", "石化", "石油", "停车", "充电", "parking"], .category("ex.traffic.fuel")),
        (["铁路", "12306", "航空", "机票", "携程", "去哪儿", "飞猪", "同程", "airline", "airways"], .category("ex.traffic.trip")),
        (["咖啡", "奶茶", "茶饮", "星巴克", "瑞幸", "喜茶", "蜜雪", "面包", "烘焙", "甜品", "便利店", "全家", "罗森", "7-eleven", "coffee", "cafe"], .category("ex.food.snack")),
        (["外卖", "美团", "饿了么", "餐", "饭", "面馆", "火锅", "烧烤", "小吃", "快餐", "食堂", "饺子", "包子", "粉", "麦当劳", "肯德基", "kfc", "mcdonald", "restaurant", "kitchen", "bistro", "grill"], .meal),
        (["超市", "便利", "淘宝", "天猫", "京东", "拼多多", "盒马", "商城", "百货", "沃尔玛", "家乐福", "山姆", "pinduoduo", "taobao", "jd.com", "mart", "market"], .category("ex.daily")),
        (["服装", "服饰", "优衣库", "zara", "uniqlo"], .category("ex.clothes.wear")),
        (["话费", "移动", "联通", "电信", "宽带", "流量"], .category("ex.home.phone")),
        (["燃气", "电费", "水费", "电力", "电网", "自来水"], .category("ex.home.utility")),
        (["房租", "租金"], .category("ex.home.rent")),
        (["电影", "影城", "影院", "猫眼", "淘票票", "游戏", "视频", "音乐", "ktv", "cinema", "netflix", "steam"], .category("ex.fun.media")),
        (["健身", "运动", "球馆", "游泳", "gym", "fitness"], .category("ex.fun.sport")),
        (["酒店", "宾馆", "民宿", "景区", "hotel", "airbnb"], .category("ex.fun.travel")),
        (["书店", "图书", "当当", "book"], .category("ex.study.book")),
        (["课程", "培训", "教育", "网课"], .category("ex.study.course")),
        (["医院", "药房", "药店", "诊所", "医疗", "pharmacy", "clinic", "hospital"], .category("ex.medical")),
    ]

    /// 猜的分类（最多一个）。只猜支出
    static func guess(_ counterparty: String?, type: CategoryType, slot: MealSlot, tree: CategoryTree) -> LedgerCategory? {
        guard type == .expense, let counterparty else { return nil }
        let text = TextNormalizer.simplifyChinese(TextNormalizer.normalizeWidth(counterparty)).lowercased()
        guard let entry = entries.first(where: { $0.words.contains { text.contains($0) } }) else { return nil }
        let category: LedgerCategory? = switch entry.target {
        case .category(let id): tree.category(id)
        case .meal: slot.mealKey.flatMap { tree.category(autoKey: $0) } ?? tree.category(autoKey: CategoryKey.food)
        }
        guard let category, category.type == type, !category.hidden, tree.category(category.parentID)?.hidden != true else { return nil }
        return category
    }
}
