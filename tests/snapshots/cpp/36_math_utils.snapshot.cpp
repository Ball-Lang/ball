
namespace {

BallDyn abs_(int64_t x);
BallDyn max_(int64_t a, int64_t b);
BallDyn min_(int64_t a, int64_t b);

BallDyn abs_(int64_t x) {
    auto& input = x;
    if ((x < static_cast<int64_t>(0))) {
        return BallDyn((-x));
    }
    return x;
    return BallDyn();
}

BallDyn max_(int64_t a, int64_t b) {
    if ((a > b)) {
        return BallDyn(a);
    }
    return b;
    return BallDyn();
}

BallDyn min_(int64_t a, int64_t b) {
    if ((a < b)) {
        return BallDyn(a);
    }
    return b;
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(abs_((-static_cast<int64_t>(5))))) << std::endl;
    std::cout << ball_to_string(ball_to_string(abs_(static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(max_(static_cast<int64_t>(10), static_cast<int64_t>(20)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(min_(static_cast<int64_t>(10), static_cast<int64_t>(20)))) << std::endl;
    return 0;
}
