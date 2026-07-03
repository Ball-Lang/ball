
namespace {

BallDyn firstPositive(int64_t a, int64_t b, int64_t c);

BallDyn firstPositive(int64_t a, int64_t b, int64_t c) {
    if ((a > static_cast<int64_t>(0))) {
        return BallDyn(a);
    }
    if ((b > static_cast<int64_t>(0))) {
        return BallDyn(b);
    }
    if ((c > static_cast<int64_t>(0))) {
        return BallDyn(c);
    }
    return static_cast<int64_t>(0);
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(firstPositive((-static_cast<int64_t>(1)), static_cast<int64_t>(5), static_cast<int64_t>(2)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(firstPositive((-static_cast<int64_t>(1)), (-static_cast<int64_t>(2)), static_cast<int64_t>(7)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(firstPositive((-static_cast<int64_t>(1)), (-static_cast<int64_t>(2)), (-static_cast<int64_t>(3))))) << std::endl;
    return 0;
}
